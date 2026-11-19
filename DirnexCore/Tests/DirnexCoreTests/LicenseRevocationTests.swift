import Foundation
import Testing

@testable import DirnexCore

/// The licenses a build no longer counts (PLAN.md §M40 Slice 7): the compiled list, how it reads a
/// key, and the status it gives.
@Suite("License revocation")
struct LicenseRevocationTests {
    private static func day(_ text: String) -> LicenseDay {
        guard let day = LicenseDay(text) else { fatalError("bad fixture day \(text)") }
        return day
    }

    /// The ids of the shared vectors, which the signer wrote.
    private static let signerIDs = [
        "5RSU7LEVTH3C46PCOBVL54R57M", "5TI3WYKTWQLQ7O7YDCUVA3ZKNI",
        "KKAG24PTKXBC7ZMCPL35MRTZSE", "T74JP3N6TINLVYHEVNOXVPEO6U"
    ]

    private static let id = signerIDs[0]
    private static let otherID = signerIDs[1]

    private static func key(id: String = id, until: String = "2027-09-29") -> LicenseKey {
        LicenseKey(
            text: "dnx1.test",
            id: id,
            licensee: "Jane",
            issued: day("2026-09-29"),
            until: day(until)
        )
    }

    /// RFC 4648 base32, upper case and unpadded, written here independently of the check.
    private static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var text = ""
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                text.append(alphabet[(buffer >> bits) & 31])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { text.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return text
    }

    // MARK: - The compiled list

    @Test("every line of the compiled list is well formed, and names its license once")
    func compiledList() {
        let entries = LicenseRevocations.compiled
        let malformed = entries.filter { !$0.isWellFormed }
        #expect(malformed.isEmpty, "\(malformed)")
        #expect(Set(entries.map(\.id)).count == entries.count)
    }

    @Test("an id is well formed exactly when the signer could have written it")
    func idFormat() {
        for id in Self.signerIDs {
            #expect(LicenseRevocation.isWellFormedID(id), "\(id)")
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let id = Self.base32((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(LicenseRevocation.isWellFormedID(id), "\(id)")
        }
        let refused = [
            "", Self.id.lowercased(), String(Self.id.dropLast()), Self.id + "A",
            // 0, 1, 8 and 9 aren't in the alphabet.
            "0RSU7LEVTH3C46PCOBVL54R57M", "5RSU7LEVTH3C46PCOBVL54R581",
            // The last character carries three bits, so N (13) can't end an id and M (12) can.
            "5RSU7LEVTH3C46PCOBVL54R57N",
            " 5RSU7LEVTH3C46PCOBVL54R57M", "5RSU7LEVTH3C46PCOBVL54R57M\n",
            "jane@example.com", "Jane Appleseed"
        ]
        for id in refused {
            #expect(!LicenseRevocation.isWellFormedID(id), "\(id)")
        }
    }

    @Test("a renewal's day must be one LicenseDay reads")
    func renewalDayFormat() {
        #expect(LicenseRevocation.renewal(Self.id, until: "2027-09-29").isWellFormed)
        #expect(!LicenseRevocation.renewal(Self.id, until: "2027-9-29").isWellFormed)
        #expect(!LicenseRevocation.renewal(Self.id, until: "2027-02-30").isWellFormed)
        #expect(LicenseRevocation.license(Self.id).isWellFormed)
    }

    // MARK: - Reading a key

    @Test("a revoked license refuses every key of it, and only those")
    func revokedLicense() {
        let list = LicenseRevocations([.license(Self.id)])
        #expect(list.applied(to: Self.key()) == .failure(.revoked))
        #expect(list.applied(to: Self.key(until: "2030-01-01")) == .failure(.revoked))
        let other = Self.key(id: Self.otherID)
        #expect(list.applied(to: other) == .success(other))
        #expect(LicenseRevocations.none.applied(to: Self.key()) == .success(Self.key()))
    }

    @Test("a renewal taken back cuts a later key back to its day, and leaves the earlier key alone")
    func renewalTakenBack() {
        let list = LicenseRevocations([.renewal(Self.id, until: "2027-09-29")])
        let renewed = Self.key(until: "2028-09-29")
        let cut = try? list.applied(to: renewed).get()
        #expect(cut?.until == Self.day("2027-09-29"))
        #expect(cut?.text == renewed.text)
        #expect(cut?.id == renewed.id)
        #expect(cut?.licensee == renewed.licensee)
        #expect(cut?.issued == renewed.issued)
        // The key the renewal replaced, and one that ends sooner still.
        for until in ["2027-09-29", "2027-06-01"] {
            let earlier = Self.key(until: until)
            #expect(list.applied(to: earlier) == .success(earlier))
        }
        let other = Self.key(id: Self.otherID, until: "2028-09-29")
        #expect(list.applied(to: other) == .success(other))
    }

    @Test("applying the list twice gives what applying it once does")
    func idempotent() throws {
        let list = LicenseRevocations([.renewal(Self.id, until: "2027-09-29")])
        let once = try list.applied(to: Self.key(until: "2028-09-29")).get()
        #expect(list.applied(to: once) == .success(once))
    }

    @Test("of several lines for one license the strictest counts, in either order")
    func strictestCounts() throws {
        let revoked: [LicenseRevocation] = [
            .license(Self.id),
            .renewal(Self.id, until: "2027-09-29")
        ]
        #expect(LicenseRevocations(revoked).applied(to: Self.key()) == .failure(.revoked))
        #expect(LicenseRevocations(revoked.reversed()).applied(to: Self.key()) == .failure(.revoked))
        let renewals: [LicenseRevocation] = [
            .renewal(Self.id, until: "2027-09-29"), .renewal(Self.id, until: "2028-09-29")
        ]
        for order in [renewals, renewals.reversed()] {
            let key = try LicenseRevocations(order).applied(to: Self.key(until: "2029-09-29")).get()
            #expect(key.until == Self.day("2027-09-29"))
        }
    }

    @Test("a renewal line whose day doesn't read takes nothing away, rather than revoking")
    func malformedRenewalIsIgnored() {
        let key = Self.key(until: "2028-09-29")
        for day in ["2027-9-29", "2027-02-30", ""] {
            let list = LicenseRevocations([.renewal(Self.id, until: day)])
            #expect(list.applied(to: key) == .success(key), "\(day)")
        }
    }

    // MARK: - Status

    @Test("a revoked key is its own status, which counts for nothing and reminds as no key does")
    func revokedStatus() {
        let key = Self.key()
        let list = LicenseRevocations([.license(Self.id)])
        // Before and after the key's end: revoked either way.
        for build in ["2027-01-01", "2028-01-01"] {
            let status = LicenseStatus(key: key, buildReleaseDay: Self.day(build), revocations: list)
            #expect(status == .revoked(key), "\(build)")
        }
        #expect(LicenseStatus(key: key, buildReleaseDay: nil, revocations: list) == .revoked(key))
        #expect(LicenseStatus.revoked(key).key == nil)
        #expect(!LicenseStatus.revoked(key).isCovered)
        #expect(LicenseStatus.revoked(key).reminderVariant == .buy)
        let other = Self.key(id: Self.otherID)
        #expect(
            LicenseStatus(key: other, buildReleaseDay: nil, revocations: list) == .licensed(other)
        )
    }

    @Test("a key whose renewal was taken back is judged by the day the license was put back to")
    func cutBackStatus() throws {
        let list = LicenseRevocations([.renewal(Self.id, until: "2027-09-29")])
        let renewed = Self.key(until: "2028-09-29")
        let cut = try list.applied(to: renewed).get()
        let covered = LicenseStatus(
            key: renewed,
            buildReleaseDay: Self.day("2027-09-29"),
            revocations: list
        )
        #expect(covered == .licensed(cut))
        let after = LicenseStatus(
            key: renewed,
            buildReleaseDay: Self.day("2027-09-30"),
            revocations: list
        )
        #expect(after == .lapsed(cut))
        #expect(after.reminderVariant == .renew(until: Self.day("2027-09-29")))
    }

    @Test("this build's status reads the compiled list")
    func defaultIsCompiled() {
        #expect(LicenseRevocations.thisBuild == LicenseRevocations(LicenseRevocations.compiled))
        let key = Self.key()
        #expect(
            LicenseStatus(key: key, buildReleaseDay: nil)
                == LicenseStatus(key: key, buildReleaseDay: nil, revocations: .thisBuild)
        )
    }
}
