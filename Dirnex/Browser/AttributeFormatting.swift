import AppKit
import DirnexCore

/// The words the attributes panel puts on screen for things `DirnexCore` models as facts
/// (PLAN.md §M14 Slice 4).
///
/// Every one of these is a *presentation* decision, which is exactly why none of them lives in the
/// core: a computed property on a core value type that returns a sentence is a string that can never
/// be translated (docs/NOTES.md — the `UpdateAvailability.tooltip` lesson). The core names the bit;
/// this names it in the user's language.
enum AttributeFormatting {
    // MARK: - Item kind

    /// What the item is — and, for a symlink, that everything shown describes the **link**.
    static func kindDescription(of snapshot: AttributesSnapshot) -> String {
        if snapshot.isSymlink {
            return String(
                localized: "Symbolic link",
                comment: "Info panel item kind. Everything shown describes the link, not its target."
            )
        }
        switch snapshot.entry.kind {
        case .directory:
            return String(localized: "Folder", comment: "Info panel item kind: a directory.")
        case .file:
            return String(localized: "File", comment: "Info panel item kind: a regular file.")
        default:
            return String(
                localized: "Other",
                comment: "Info panel item kind: something that is not a file, folder or symlink."
            )
        }
    }

    // MARK: - Numbers and dates

    /// Follows the current locale for free, as every other size in the app does.
    static func byteSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// `rw-r--r--  (644)` — both spellings, because one is what `ls` shows and the other is what a
    /// user types at `chmod`. Shared by the initial render and the live echo the editable grid drives,
    /// so the octal never disagrees with the checkboxes.
    static func modeDescription(_ permissions: POSIXPermissions) -> String {
        // The literal must stay single (a concatenation extracts nothing — docs/NOTES.md); the values
        // it interpolates need not be spelled out inside it.
        let symbolic = permissions.symbolicString
        let octal = permissions.octalString
        return String(
            localized: "\(symbolic)  (\(octal))",
            comment: "Info panel mode: %1$@ is the rwx string, %2$@ the octal digits."
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    // MARK: - BSD file flags

    /// The owner-settable flags the panel offers as checkboxes, in display order. `SF_*` flags are
    /// deliberately absent — they need root and are reported as a note instead
    /// (``systemFlagsDescription(_:)``), so a read-only panel never implies they are togglable.
    static let editableFlags: [(flag: BSDFileFlags, title: String)] = [
        (.userImmutable, String(
            localized: "Locked",
            comment: "BSD file flag UF_IMMUTABLE — the name Finder's Get Info uses for it."
        )),
        (.hidden, String(
            localized: "Hidden",
            comment: "BSD file flag UF_HIDDEN — the item is hinted as not to be displayed."
        )),
        (.userAppend, String(
            localized: "Append only",
            comment: "BSD file flag UF_APPEND — writes may only add to the end of the file."
        )),
        (.noDump, String(
            localized: "Skip backups",
            comment: "BSD file flag UF_NODUMP — do not include the item in a dump/backup."
        )),
        (.opaque, String(
            localized: "Opaque",
            comment: "BSD file flag UF_OPAQUE — the directory is opaque to a union mount."
        ))
    ]

    /// The root-only flags currently set, named — or `nil` when none are. Never a checkbox: an owner
    /// gets `EPERM` on every `SF_*` flag even for their own file (M14 probe), so offering one as a
    /// toggle would promise something the panel cannot do.
    static func systemFlagsDescription(_ flags: BSDFileFlags) -> String? {
        var names: [String] = []
        if flags.contains(.systemImmutable) {
            names.append(String(
                localized: "system locked",
                comment: "BSD flag SF_IMMUTABLE, listed in a sentence. Only root can change it."
            ))
        }
        if flags.contains(.systemAppend) {
            names.append(String(
                localized: "system append only",
                comment: "BSD flag SF_APPEND, listed in a sentence. Only root can change it."
            ))
        }
        if flags.contains(.archived) {
            names.append(String(
                localized: "archived",
                comment: "BSD flag SF_ARCHIVED, listed in a sentence. Only root can change it."
            ))
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: - ACL

    /// An entry's disposition, as the word the row shows.
    static func disposition(_ disposition: ACLDisposition) -> String {
        disposition == .allow
            ? String(localized: "Allow", comment: "ACL entry grants the rights it names.")
            : String(localized: "Deny", comment: "ACL entry refuses the rights it names.")
    }

    /// One right's label for an item of this kind.
    ///
    /// The four aliased bits are relabelled on a directory — `read` reads as "List", `write` as "Add
    /// File" and so on — because that is what `ls -le` and `chmod +a` call them there, and a folder
    /// whose ACL says "read" would not match what every other tool on the Mac shows. The *stored*
    /// token never changes; this is only the word (docs/NOTES.md).
    static func right(_ right: ACLRight, on kind: FileEntry.Kind) -> String {
        if kind == .directory, let alias = right.directoryAlias {
            return directoryRightTitles[alias] ?? alias
        }
        return rightTitles[right] ?? right.rawValue
    }

    /// The rights an entry carries, in canonical order, joined for the row's summary column.
    /// Unrecognized tokens are appended verbatim — they are kept rather than dropped, so a right a
    /// later macOS adds is visible here instead of silently missing.
    static func rights(of entry: ACLEntry, on kind: FileEntry.Kind) -> String {
        let known = ACLRight.allCases
            .filter { entry.rights.contains($0) }
            .map { right($0, on: kind) }
        return (known + entry.unrecognizedRights).joined(separator: ", ")
    }

    /// The inheritance controls an entry carries, named — or `nil` when it carries none.
    static func inheritance(of entry: ACLEntry) -> String? {
        var names: [String] = []
        for (option, title) in inheritanceTitles where entry.inheritance.contains(option) {
            names.append(title)
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private static let rightTitles: [ACLRight: String] = [
        .delete: String(localized: "Delete", comment: "ACL right: delete this item."),
        .readAttributes: String(
            localized: "Read Attributes", comment: "ACL right readattr: read basic attributes."
        ),
        .writeAttributes: String(
            localized: "Write Attributes", comment: "ACL right writeattr: change basic attributes."
        ),
        .readExtendedAttributes: String(
            localized: "Read Extended Attributes", comment: "ACL right readextattr."
        ),
        .writeExtendedAttributes: String(
            localized: "Write Extended Attributes", comment: "ACL right writeextattr."
        ),
        .readSecurity: String(
            localized: "Read Permissions", comment: "ACL right readsecurity: read the ACL itself."
        ),
        .writeSecurity: String(
            localized: "Change Permissions", comment: "ACL right writesecurity: change the ACL."
        ),
        .takeOwnership: String(
            localized: "Take Ownership", comment: "ACL right chown: become the item's owner."
        ),
        .read: String(localized: "Read", comment: "ACL right read: read a file's data."),
        .write: String(localized: "Write", comment: "ACL right write: write a file's data."),
        .execute: String(localized: "Execute", comment: "ACL right execute: run a file."),
        .append: String(
            localized: "Append", comment: "ACL right append: add to the end of a file."
        ),
        .deleteChild: String(
            localized: "Delete Contents",
            comment: "ACL right delete_child: delete items inside this folder."
        )
    ]

    /// The directory spellings, keyed by the alias token `ACLRight.directoryAlias` hands back.
    private static let directoryRightTitles: [String: String] = [
        "list": String(
            localized: "List", comment: "ACL right on a folder (list): see what is inside it."
        ),
        "add_file": String(
            localized: "Add File", comment: "ACL right on a folder (add_file): create a file in it."
        ),
        "search": String(
            localized: "Traverse",
            comment: "ACL right on a folder (search): reach items inside without listing it."
        ),
        "add_subdirectory": String(
            localized: "Add Folder",
            comment: "ACL right on a folder (add_subdirectory): create a subfolder in it."
        )
    ]

    private static let inheritanceTitles: [(ACLInheritance, String)] = [
        (.fileInherit, String(
            localized: "files inherit", comment: "ACL inheritance flag file_inherit, in a list."
        )),
        (.directoryInherit, String(
            localized: "folders inherit",
            comment: "ACL inheritance flag directory_inherit, in a list."
        )),
        (.limitInherit, String(
            localized: "limit inheritance",
            comment: "ACL inheritance flag limit_inherit, in a list."
        )),
        (.onlyInherit, String(
            localized: "inherit only", comment: "ACL inheritance flag only_inherit, in a list."
        ))
    ]

    // MARK: - Extended attributes

    /// A one-line rendering of an attribute's value, chosen by what the bytes actually are.
    static func value(of attribute: ExtendedAttribute) -> String {
        switch attribute.value {
        case let .text(text):
            return text.replacingOccurrences(of: "\n", with: " ")
        case .propertyList:
            return String(
                localized: "Property list, \(AttributeFormatting.byteSize(Int64(attribute.data.count)))",
                comment: "Extended attribute value summary for a plist; %@ is its size."
            )
        case .binary:
            return attribute.hexPreview()
        }
    }
}
