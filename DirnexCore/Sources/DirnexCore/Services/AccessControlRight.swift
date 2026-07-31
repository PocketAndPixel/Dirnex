import Foundation

/// One ACL right, spelled as `acl_to_text` writes it in the canonical form (PLAN.md §M14 Slice 3).
///
/// **The token set is the one `acl_to_text` produces, which is not the one `chmod(1)` documents.**
/// Probed live (2026-07-29..30): four rights are aliased bits that the kernel prints with their
/// *file* names even on a directory — `list`≡`read`, `add_file`≡`write`, `search`≡`execute`,
/// `add_subdirectory`≡`append` — so `acl_to_text` (and therefore this parser) only ever sees
/// `read/write/execute/append`, while `ls -le` shows the directory spellings for the same bits. Only
/// `delete_child` is a genuinely directory-only token in canonical text. Modelling the *bits*
/// (13 of them) rather than `chmod`'s 17 input tokens is what keeps a directory ACL from carrying the
/// same bit twice under two names.
///
/// So the count the panel shows still works out: a file offers the 12 that apply to it, a directory
/// offers 13 (adding `delete_child`) plus the four inheritance flags from ``ACLInheritance`` — the 17
/// checkboxes a folder shows. The four ``dataRights`` are relabelled per kind at the display layer
/// (``directoryAlias``), which is a presentation choice, not a second right.
///
/// The raw value is the exact canonical token, so a parsed right round-trips to the identical
/// spelling. A token this build does not know is **not dropped** — ``ACLEntry`` keeps it verbatim so
/// writing an ACL back never silently strips a right macOS added later.
public enum ACLRight: String, Sendable, Hashable, CaseIterable, Codable {
    // Common — apply to any item (8).
    case delete
    case readAttributes = "readattr"
    case writeAttributes = "writeattr"
    case readExtendedAttributes = "readextattr"
    case writeExtendedAttributes = "writeextattr"
    case readSecurity = "readsecurity"
    case writeSecurity = "writesecurity"
    case takeOwnership = "chown"

    // Data rights — the four aliased bits, spelled the file way in canonical text for any kind (4).
    case read
    case write
    case execute
    case append

    // Directory-only, with no file alias (1).
    case deleteChild = "delete_child"

    /// The eight rights every item has.
    public static let common: [ACLRight] = [
        .delete, .readAttributes, .writeAttributes, .readExtendedAttributes,
        .writeExtendedAttributes, .readSecurity, .writeSecurity, .takeOwnership
    ]

    /// The four aliased bits, in file order. On a directory these are shown as
    /// list/add_file/search/add_subdirectory (see ``directoryAlias``) but stored as these tokens.
    public static let dataRights: [ACLRight] = [.read, .write, .execute, .append]

    /// The twelve rights offerable for a non-directory.
    public static let fileRights: [ACLRight] = common + dataRights

    /// The thirteen rights offerable for a directory — the file set plus `delete_child`.
    public static let directoryRights: [ACLRight] = common + dataRights + [.deleteChild]

    /// The ordered rights offerable for an item of this kind. A symlink is treated as a file (its own
    /// ACL, not its target's), matching the applier acting on the link.
    public static func applicable(to kind: FileEntry.Kind) -> [ACLRight] {
        kind == .directory ? directoryRights : fileRights
    }

    /// The directory spelling `ls -le` and `chmod +a` use for a ``dataRights`` bit, or `nil` for a
    /// right that is not relabelled on a directory. The stored token never changes; this is only how
    /// a folder's editor and a hand-off `chmod` command name the same bit.
    public var directoryAlias: String? {
        switch self {
        case .read: return "list"
        case .write: return "add_file"
        case .execute: return "search"
        case .append: return "add_subdirectory"
        default: return nil
        }
    }
}
