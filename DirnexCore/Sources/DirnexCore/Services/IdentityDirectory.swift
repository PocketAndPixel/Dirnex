import Foundation

/// One account the panel can name: a user or a group, with its numeric id (PLAN.md §M14 Slice 4).
///
/// This is the display half of an ACL subject. ``ACLIdentity`` turns the numeric id into the GUID
/// macOS actually stores; this turns it into the name a person recognizes, and back.
public struct IdentityRecord: Sendable, Hashable, Comparable {
    public let name: String
    public let numericID: UInt32

    public init(name: String, numericID: UInt32) {
        self.name = name
        self.numericID = numericID
    }

    /// A macOS **service account**, spelled with a leading underscore by convention (`_spotlight`,
    /// `_windowserver`). Hidden from the picker — see ``IdentityRoster/visible(_:)``.
    public var isServiceAccount: Bool { name.hasPrefix("_") }

    /// Sorted by name, case-insensitively, which is the order a picker lists them in.
    public static func < (lhs: IdentityRecord, rhs: IdentityRecord) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// The pure rules that turn what `getpwent`/`getgrent` hand back into a list worth showing — split
/// from the enumeration itself so every rule is testable without depending on the accounts that
/// happen to exist on the machine running the tests (the ``ByteComparator``/`ComparisonSubject`
/// shape).
///
/// Two findings from the live probe (2026-07-31) are encoded here, and both are invisible until
/// someone looks:
///
/// - **The enumerators return every record twice.** Measured on this Mac: 265 `getpwent` records for
///   133 distinct accounts and 322 `getgrent` records for 161 groups — Open Directory answering from
///   both the local node and the search path. `dscl . list /Users` independently reports exactly the
///   de-duplicated counts, which is the OS agreeing. Without ``deduplicated(_:)`` every name in the
///   picker appears twice.
/// - **The filter must be by name, not by id.** After de-duplication the leading-underscore rule
///   leaves 4 users and 34 groups — including `staff` (20), `admin` (80), `everyone` (12) and
///   `wheel` (0). The tempting "real accounts start at 500" numeric rule would have hidden all four,
///   and those are precisely the groups an ACL entry names.
public enum IdentityRoster {
    /// Collapse the duplicate records, keeping first-seen order.
    public static func deduplicated(_ records: [IdentityRecord]) -> [IdentityRecord] {
        var seen: Set<IdentityRecord> = []
        return records.filter { seen.insert($0).inserted }
    }

    /// The accounts a picker offers: de-duplicated, service accounts dropped, sorted by name.
    public static func visible(_ records: [IdentityRecord]) -> [IdentityRecord] {
        deduplicated(records).filter { !$0.isServiceAccount }.sorted()
    }
}

/// Enumerates the machine's users and groups and resolves ids to names — the thin, non-pure half
/// behind ``IdentityRoster``.
///
/// Everything goes through `getpwent`/`getgrent` and the `getpwuid`/`getgrgid` lookups rather than
/// Open Directory's own API: they are what `acl_to_text` and `ls -l` themselves resolve names with,
/// so the panel and the OS's tools always agree about who a numeric id is.
public enum IdentityDirectory {
    /// Every user account on the machine, de-duplicated and in first-seen order (service accounts
    /// included — ``IdentityRoster/visible(_:)`` is what a picker applies).
    public static func users() -> [IdentityRecord] {
        setpwent()
        defer { endpwent() }
        var records: [IdentityRecord] = []
        while let entry = getpwent() {
            records.append(
                IdentityRecord(
                    name: String(cString: entry.pointee.pw_name),
                    numericID: entry.pointee.pw_uid
                )
            )
        }
        return IdentityRoster.deduplicated(records)
    }

    /// Every group on the machine, de-duplicated and in first-seen order.
    public static func groups() -> [IdentityRecord] {
        setgrent()
        defer { endgrent() }
        var records: [IdentityRecord] = []
        while let entry = getgrent() {
            records.append(
                IdentityRecord(
                    name: String(cString: entry.pointee.gr_name),
                    numericID: entry.pointee.gr_gid
                )
            )
        }
        return IdentityRoster.deduplicated(records)
    }

    /// The user name for a uid, or `nil` if the id resolves to no account.
    ///
    /// Note the asymmetry with ``ACLIdentity/guid(forUserID:)``, which **synthesizes** a GUID for an
    /// id that has no account (probed: uid 31337 → `FFFFEEEE-…-AAAA00007A69`). So a GUID coming back
    /// non-`nil` proves nothing about existence, and *this* is the call that answers "is there
    /// really such a user" — the one a subject picker must validate against.
    public static func userName(for userID: UInt32) -> String? {
        getpwuid(userID).map { String(cString: $0.pointee.pw_name) }
    }

    /// The group name for a gid, or `nil` if the id resolves to no group.
    public static func groupName(for groupID: UInt32) -> String? {
        getgrgid(groupID).map { String(cString: $0.pointee.gr_name) }
    }

    /// The uid for a user name, or `nil` if unknown.
    public static func userID(for name: String) -> UInt32? {
        getpwnam(name).map { $0.pointee.pw_uid }
    }

    /// The gid for a group name, or `nil` if unknown.
    public static func groupID(for name: String) -> UInt32? {
        getgrnam(name).map { $0.pointee.gr_gid }
    }
}
