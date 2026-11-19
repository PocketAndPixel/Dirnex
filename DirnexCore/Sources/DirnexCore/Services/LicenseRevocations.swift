import Foundation

/// One license the store took back, as its server now records it (PLAN.md §M40 "Revoked keys").
///
/// Two things can be taken back, and the server keeps them apart. A full refund, a chargeback or a
/// revocation by hand revokes the **license**, so no key of it counts any more. A refunded
/// **renewal** only puts the license's old dates back (`undoRenewal` in the store's server): the
/// license still covers what it covered before, while the key the renewal sent, which has the same
/// id and a later end day, would go on covering the renewed year. So that entry names the end day
/// the license was put back to, and a key of it reads as ending there.
///
/// An entry names a license only by its id, 128 random bits that already go into a URL
/// (`LicenseKey.id`), so the list can ship in this open repository without naming anyone.
public struct LicenseRevocation: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The license is revoked: every key of it counts for nothing.
        case license
        /// A renewal was taken back: the license covers releases up to this day, `YYYY-MM-DD`, as
        /// the server now has it.
        case renewal(until: String)
    }

    public let id: String
    public let kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The license with this id is revoked.
    public static func license(_ id: String) -> LicenseRevocation {
        LicenseRevocation(id: id, kind: .license)
    }

    /// A renewal of the license with this id was taken back, and the license now ends on `until`.
    public static func renewal(_ id: String, until: String) -> LicenseRevocation {
        LicenseRevocation(id: id, kind: .renewal(until: until))
    }

    /// Whether the entry is one the signer could have produced: an id of 26 characters of RFC 4648
    /// base32, upper case and unpadded, as `encodeBase32(randomBytes(16))` writes it, and for a
    /// renewal a day `LicenseDay` reads. The last of the 26 characters carries only three of the 128
    /// bits, so its two low bits are always zero. A test runs this over the compiled list, since an
    /// entry that fails it matches no key and would revoke nothing in silence.
    public var isWellFormed: Bool {
        guard Self.isWellFormedID(id) else { return false }
        switch kind {
        case .license: return true
        case let .renewal(until): return LicenseDay(until) != nil
        }
    }

    private static let base32 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func isWellFormedID(_ id: String) -> Bool {
        let values = id.utf8.compactMap { base32.firstIndex(of: $0) }
        guard id.utf8.count == 26, values.count == 26, let last = values.last else { return false }
        return last & 0b11 == 0
    }
}

/// Why a key that may have verified still doesn't count.
public enum LicenseRefusal: Error, Sendable, Equatable {
    /// The text isn't a key this build accepts, for the reason the verifier gave.
    case invalid(LicenseKeyError)
    /// The key verified, and its license is on ``LicenseRevocations``.
    case revoked
}

extension LicenseRefusal: CaseIterable {
    public static var allCases: [LicenseRefusal] {
        LicenseKeyError.allCases.map(LicenseRefusal.invalid) + [.revoked]
    }
}

/// The licenses this build no longer counts (PLAN.md §M40 "Revoked keys").
///
/// Dirnex never asks a server whether a license is real, so what the store took back reaches the
/// app the way everything else does, in a release: the list is compiled in (``thisBuild``). A build
/// carries the list as it was when the build was made, so an earlier build goes on accepting a key
/// revoked later, which is the price of checking offline. The reminder is a request, not a lock.
///
/// The list is applied **after** the signature: a key that doesn't verify is refused for that
/// reason, whatever its id. And it never deletes anything. A revoked key stays stored, so taking
/// its entry off the list restores it.
public struct LicenseRevocations: Sendable, Equatable {
    /// Per id, the end day the license was put back to, or `nil` when the whole license is revoked.
    private let entries: [String: LicenseDay?]

    /// The list from `revocations`. When one license has several entries, the strictest counts: a
    /// revoked license stays revoked, and of two renewals taken back, the earlier day wins. An entry
    /// that isn't ``LicenseRevocation/isWellFormed`` is left out, since a mistake in the list must
    /// never take a license away from someone it doesn't name.
    public init(_ revocations: [LicenseRevocation]) {
        var entries: [String: LicenseDay?] = [:]
        for revocation in revocations where revocation.isWellFormed {
            let until: LicenseDay? = switch revocation.kind {
            case .license: nil
            case let .renewal(until): LicenseDay(until)
            }
            // `updateValue` rather than the subscript, where a revoked license's `nil` day reads like
            // a removal. The subscript would store it too, since a typed `nil` is wrapped.
            entries.updateValue(Self.stricter(entries[revocation.id], until), forKey: revocation.id)
        }
        self.entries = entries
    }

    /// An empty list.
    public static let none = LicenseRevocations([])

    /// The list this build carries.
    public static let thisBuild = LicenseRevocations(compiled)

    /// The licenses the store took back, one line each, as its admin page shows them: `.license(id)`
    /// for a revoked license, and `.renewal(id, until: "YYYY-MM-DD")` for one whose renewal was
    /// refunded, with the end day the license has now. A trailing comment may give the day the line
    /// was added, and nothing else: not the reason, no name and no address, since the store's Privacy
    /// Policy says the list holds only the id. `LicenseRevocationTests` checks every line.
    static let compiled: [LicenseRevocation] = []

    /// `key` as the list reads it: refused as ``LicenseRefusal/revoked`` when its license is revoked,
    /// ending on the day a renewal was taken back to when that is before the key's own end, and
    /// otherwise unchanged. Applying it twice gives the same answer as once.
    public func applied(to key: LicenseKey) -> Result<LicenseKey, LicenseRefusal> {
        guard let entry = entries[key.id] else { return .success(key) }
        guard let until = entry else { return .failure(.revoked) }
        guard until < key.until else { return .success(key) }
        return .success(LicenseKey(
            text: key.text,
            id: key.id,
            licensee: key.licensee,
            issued: key.issued,
            until: until
        ))
    }

    private static func stricter(_ held: LicenseDay??, _ new: LicenseDay?) -> LicenseDay? {
        guard let held else { return new }
        guard let held, let new else { return nil }
        return min(held, new)
    }
}
