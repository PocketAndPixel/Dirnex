import Foundation

/// Resolves a uid or gid to the **GUID** macOS spells ACL subjects by — the one thing the subject
/// picker needs and the parse/serialize pair does not (PLAN.md §M14 Slice 3).
///
/// `mbr_uid_to_uuid` / `mbr_gid_to_uuid` live in `membership.h`, which is outside the Darwin module
/// map, so they are not visible to Swift by name. Rather than add a module-map target (which would
/// ripple into the app's build graph), they are resolved through `dlsym` against `RTLD_DEFAULT` —
/// the "small dlsym declaration" PLAN.md explicitly allows. The probe (2026-07-29..30) confirmed the
/// symbols resolve and that the GUID they return is byte-identical to the one `acl_to_text` prints
/// for the same id, which is what the live test pins so a symbol that ever moves fails loudly.
public enum ACLIdentity {
    /// The canonical GUID string (uppercase, hyphenated — `acl_to_text`'s own form) for a user id, or
    /// `nil` if the id does not resolve.
    public static func guid(forUserID userID: UInt32) -> String? {
        resolve(userID, symbol: "mbr_uid_to_uuid")
    }

    /// The canonical GUID string for a group id, or `nil` if it does not resolve.
    public static func guid(forGroupID groupID: UInt32) -> String? {
        resolve(groupID, symbol: "mbr_gid_to_uuid")
    }

    /// The complete ``ACLSubject`` for an account the picker chose — the one place a name becomes an
    /// identity, since `acl_from_text` needs the GUID, the name *and* the numeric id (probed: an
    /// entry missing either of the last two is `EINVAL`).
    ///
    /// `nil` only when the id has no GUID at all. It is **not** an existence check: `mbr_*_to_uuid`
    /// synthesizes a GUID for an id with no account behind it (probed — uid 31337 answers
    /// `FFFFEEEE-…-AAAA00007A69`), so a picker that must reject an unknown account asks
    /// ``IdentityDirectory/userName(for:)`` instead.
    public static func subject(for record: IdentityRecord, kind: ACLSubjectKind) -> ACLSubject? {
        let guid = kind == .user
            ? guid(forUserID: record.numericID)
            : guid(forGroupID: record.numericID)
        guard let guid else { return nil }
        return ACLSubject(
            kind: kind, guid: guid, name: record.name, numericID: record.numericID
        )
    }

    // MARK: - dlsym plumbing

    private typealias MembershipToUUID = @convention(c) (UInt32, UnsafeMutablePointer<UInt8>) -> Int32

    private static func resolve(_ id: UInt32, symbol: String) -> String? {
        // `RTLD_DEFAULT` (the pseudo-handle -2) — search every loaded image, where libSystem's
        // `mbr_*` live. Recomputed per call rather than stored, so nothing is a mutable global.
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let raw = dlsym(defaultHandle, symbol) else { return nil }
        let function = unsafeBitCast(raw, to: MembershipToUUID.self)
        var bytes = [UInt8](repeating: 0, count: 16)
        guard function(id, &bytes) == 0 else { return nil }
        return bytes.withUnsafeBytes { buffer in
            UUID(uuid: buffer.load(as: uuid_t.self)).uuidString
        }
    }
}
