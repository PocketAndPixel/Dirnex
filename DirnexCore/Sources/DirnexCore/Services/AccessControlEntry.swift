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
public enum ACLSubjectKind: String, Sendable, Hashable {
    case user
    case group
}

/// Who an ACL entry is about. macOS spells subjects by **GUID**; the name and numeric id are what
/// `acl_to_text` resolves for display, and all three are required for `acl_from_text` to accept the
/// canonical form (probed: an entry missing the name or id is `EINVAL`).
public struct ACLSubject: Sendable, Hashable {
    public let kind: ACLSubjectKind
    /// The canonical UUID string, the identity macOS actually stores.
    public let guid: String
    /// The resolved user/group name, for display.
    public let name: String
    /// The uid or gid.
    public let numericID: UInt32

    public init(kind: ACLSubjectKind, guid: String, name: String, numericID: UInt32) {
        self.kind = kind
        self.guid = guid
        self.name = name
        self.numericID = numericID
    }
}

/// An entry either grants (`allow`) or refuses (`deny`) its rights. Because entries are evaluated in
/// order, a deny before an allow means something different from the same pair reversed — which is
/// why ``AccessControlList`` is an ordered list, never a set.
public enum ACLDisposition: String, Sendable, Hashable {
    case allow
    case deny
}

/// The inheritance bits carried in an entry's flags field — the four directory-only controls plus the
/// read-only `inherited` marker. The four `*_inherit` controls only apply to a directory (a file has
/// no children to propagate to); `inherited` can appear on any item, marking an entry a directory
/// above handed down, which the editor shows distinctly and does not casually edit in place.
public struct ACLInheritance: OptionSet, Sendable, Hashable {
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
public struct ACLEntry: Sendable, Hashable {
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

    // MARK: - Canonical text (one logical line)

    /// Parse one unwrapped canonical entry line — `type:guid:name:id:flags:rights`.
    static func parse(line: String) throws -> ACLEntry {
        let fields = line.components(separatedBy: ":")
        guard fields.count == 6,
              let kind = ACLSubjectKind(rawValue: fields[0]),
              let numericID = UInt32(fields[3])
        else { throw ACLError.malformedEntry(line) }

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
        for token in fields[5].split(separator: ",", omittingEmptySubsequences: true).map(
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
            String(subject.numericID),
            flagsField.joined(separator: ","),
            rightsField.joined(separator: ",")
        ].joined(separator: ":")
    }
}
