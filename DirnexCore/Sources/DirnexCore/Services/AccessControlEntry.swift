import Foundation

/// A parse failure in canonical ACL text. Not a user-facing sentence: the text a reader hands in is
/// `acl_to_text`'s own output, so a malformed line is an invariant violation, not something the user
/// typed — the write path's failures are `errno` → `VFSError`, as everywhere else in the VFS layer.
public enum ACLError: Error, Sendable, Equatable {
    /// A non-empty, non-header line did not split into the six canonical fields, or a field was not
    /// the expected shape (unknown subject kind, non-numeric id, missing allow/deny).
    case malformedEntry(String)
}

/// Whether an ACL subject is a user or a group.
public enum ACLSubjectKind: String, Sendable, Hashable, Codable {
    case user
    case group
}

/// Who an ACL entry is about. macOS spells subjects by **GUID**; the name and numeric id are what
/// `acl_to_text` resolves for display, and the canonical form needs a *field* for each of the three
/// (probed: `user:GUID::allow:read`, with the id field missing entirely, is `EINVAL`).
///
/// **The GUID is the identity and the other two are its resolution, which can be absent.** Probed
/// 2026-07-31: handing `acl_from_text` a subject with a name and id it does not believe
/// (`user:FFFFEEEE-…-AAAA00007A69:ghost:31337:allow:read`) is accepted and written back as
/// `user:FFFFEEEE-…:::allow:read` — the kernel re-derives both fields from the GUID and empties them
/// when nothing answers. So an ACL naming a deleted account, or one copied from another Mac, is an
/// ordinary state the OS both produces and displays (`ls -le` shows the bare GUID), and ``numericID``
/// is optional because a real file can arrive without one.
public struct ACLSubject: Sendable, Hashable, Codable {
    public let kind: ACLSubjectKind
    /// The canonical UUID string, the identity macOS actually stores.
    public let guid: String
    /// The resolved user/group name, or `""` when the GUID answers to no account on this machine.
    public let name: String
    /// The uid or gid, or `nil` when the GUID answers to no account.
    public let numericID: UInt32?

    public init(kind: ACLSubjectKind, guid: String, name: String, numericID: UInt32?) {
        self.kind = kind
        self.guid = guid
        self.name = name
        self.numericID = numericID
    }

    /// Whether the GUID resolves to a real account on this machine. An unresolved subject is shown
    /// as-is and written back untouched — never "repaired", since the GUID is the only thing that
    /// carries meaning and inventing a name for it would name the wrong account.
    public var isResolved: Bool { !name.isEmpty && numericID != nil }

    /// What to display: the account name, or the bare GUID when there is none — which is exactly
    /// what `ls -le` falls back to for the same entry.
    public var displayName: String { name.isEmpty ? guid : name }
}

/// An entry either grants (`allow`) or refuses (`deny`) its rights. Because entries are evaluated in
/// order, a deny before an allow means something different from the same pair reversed — which is
/// why ``AccessControlList`` is an ordered list, never a set.
public enum ACLDisposition: String, Sendable, Hashable, Codable {
    case allow
    case deny
}

/// The inheritance bits carried in an entry's flags field — the four directory-only controls plus the
/// read-only `inherited` marker. The four `*_inherit` controls only apply to a directory (a file has
/// no children to propagate to); `inherited` can appear on any item, marking an entry a directory
/// above handed down, which the editor shows distinctly and does not casually edit in place.
public struct ACLInheritance: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let fileInherit = ACLInheritance(rawValue: 1 << 0)
    public static let directoryInherit = ACLInheritance(rawValue: 1 << 1)
    public static let limitInherit = ACLInheritance(rawValue: 1 << 2)
    public static let onlyInherit = ACLInheritance(rawValue: 1 << 3)
    /// This entry was inherited from a parent directory — read-only, shown as inherited.
    public static let inherited = ACLInheritance(rawValue: 1 << 4)

    /// The four directory-only controls a directory's editor offers as checkboxes.
    public static let directoryControls: [ACLInheritance] = [
        .fileInherit, .directoryInherit, .limitInherit, .onlyInherit
    ]

    /// Token ↔ option, in the order tokens are written back into the flags field (`inherited` last,
    /// where `acl_to_text` also puts a marker relative to the controls).
    static let tokenTable: [(token: String, option: ACLInheritance)] = [
        ("file_inherit", .fileInherit),
        ("directory_inherit", .directoryInherit),
        ("limit_inherit", .limitInherit),
        ("only_inherit", .onlyInherit),
        ("inherited", .inherited)
    ]

    static func option(for token: String) -> ACLInheritance? {
        tokenTable.first { $0.token == token }?.option
    }
}

/// One access-control entry: a subject, an allow/deny, its inheritance bits, and the rights it
/// covers. Unknown tokens in either the flags field or the rights field are **kept verbatim** so
/// serializing an entry back never strips a flag or right this build does not model.
public struct ACLEntry: Sendable, Hashable, Codable {
    public var subject: ACLSubject
    public var disposition: ACLDisposition
    public var inheritance: ACLInheritance
    public var rights: Set<ACLRight>
    /// Rights tokens this build does not recognize, preserved for a lossless round-trip.
    public var unrecognizedRights: [String]
    /// Flags-field tokens (other than allow/deny) this build does not recognize, preserved verbatim.
    public var unrecognizedFlags: [String]

    public init(
        subject: ACLSubject,
        disposition: ACLDisposition,
        inheritance: ACLInheritance = [],
        rights: Set<ACLRight>,
        unrecognizedRights: [String] = [],
        unrecognizedFlags: [String] = []
    ) {
        self.subject = subject
        self.disposition = disposition
        self.inheritance = inheritance
        self.rights = rights
        self.unrecognizedRights = unrecognizedRights
        self.unrecognizedFlags = unrecognizedFlags
    }

    /// An entry a parent directory handed down. Shown as inherited and not casually edited in place.
    public var isInherited: Bool { inheritance.contains(.inherited) }

    /// Whether this entry grants or denies anything at all.
    ///
    /// **An entry with no rights is a state the OS stores happily and that does nothing.** Probed
    /// 2026-07-31: `acl_from_text` accepts an empty rights field, `acl_set_file` writes it, and
    /// `ls -le` shows `0: group:staff allow` — an entry occupying a position in the evaluation order
    /// while allowing and denying nothing. The editor refuses to create one, which is why this is a
    /// rule here rather than a check in a dialog.
    public var isMeaningful: Bool { !rights.isEmpty || !unrecognizedRights.isEmpty }

    // MARK: - Canonical text (one logical line)

    /// Parse one unwrapped canonical entry line — `type:guid:name:id:flags:rights`.
    ///
    /// Tolerant of the two shapes the OS itself writes and the strict six-field reading rejected —
    /// both probed against real files, and both of which used to make the *whole* ACL fail to parse
    /// and a file carrying one report as having no ACL at all:
    ///
    /// - **Five fields**, when the entry has no rights: `acl_to_text` omits the trailing field
    ///   entirely rather than writing it empty (`group:GUID:staff:20:allow`).
    /// - **An empty name and id**, when the GUID answers to no account: `user:GUID:::allow:read`.
    static func parse(line: String) throws -> ACLEntry {
        let fields = line.components(separatedBy: ":")
        guard (5...6).contains(fields.count),
              let kind = ACLSubjectKind(rawValue: fields[0])
        else { throw ACLError.malformedEntry(line) }
        // An absent id is legitimate; a *malformed* one is not, so the two are distinguished rather
        // than both falling through to nil.
        let numericID = UInt32(fields[3])
        guard fields[3].isEmpty || numericID != nil else { throw ACLError.malformedEntry(line) }

        let flagTokens = fields[4].split(separator: ",", omittingEmptySubsequences: true).map(
            String.init
        )
        guard let first = flagTokens.first, let disposition = ACLDisposition(rawValue: first) else {
            throw ACLError.malformedEntry(line)
        }
        var inheritance: ACLInheritance = []
        var unrecognizedFlags: [String] = []
        for token in flagTokens.dropFirst() {
            if let option = ACLInheritance.option(for: token) {
                inheritance.insert(option)
            } else {
                unrecognizedFlags.append(token)
            }
        }

        var rights: Set<ACLRight> = []
        var unrecognizedRights: [String] = []
        let rightsField = fields.count == 6 ? fields[5] : ""
        for token in rightsField.split(separator: ",", omittingEmptySubsequences: true).map(
            String.init
        ) {
            if let right = ACLRight(rawValue: token) {
                rights.insert(right)
            } else {
                unrecognizedRights.append(token)
            }
        }

        return ACLEntry(
            subject: ACLSubject(kind: kind, guid: fields[1], name: fields[2], numericID: numericID),
            disposition: disposition,
            inheritance: inheritance,
            rights: rights,
            unrecognizedRights: unrecognizedRights,
            unrecognizedFlags: unrecognizedFlags
        )
    }

    /// Serialize to one unwrapped canonical line. Rights are emitted in ``ACLRight/allCases`` order so
    /// the output is deterministic; the kernel re-canonicalizes on `acl_set_file` regardless.
    ///
    /// Always six fields, with an unresolved subject's name and id written **empty** — probed, that is
    /// both what the OS writes for such an entry and what `acl_from_text` accepts back, so an ACL
    /// naming a deleted account survives an edit to its neighbours untouched.
    func canonicalLine() -> String {
        var flagsField = [disposition.rawValue]
        for (token, option) in ACLInheritance.tokenTable where inheritance.contains(option) {
            flagsField.append(token)
        }
        flagsField.append(contentsOf: unrecognizedFlags)

        var rightsField = ACLRight.allCases.filter { rights.contains($0) }.map(\.rawValue)
        rightsField.append(contentsOf: unrecognizedRights)

        return [
            subject.kind.rawValue,
            subject.guid,
            subject.name,
            subject.numericID.map(String.init) ?? "",
            flagsField.joined(separator: ","),
            rightsField.joined(separator: ",")
        ].joined(separator: ":")
    }
}
