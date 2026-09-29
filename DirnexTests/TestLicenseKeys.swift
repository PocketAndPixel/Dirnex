import CryptoKit
import Foundation

/// License keys signed with the signer's **test** key, for the app tests (PLAN.md §M29).
///
/// The private half is derived exactly as `tools/license/src/vectors.ts` derives it in the private
/// repo: the SHA-256 of a fixed phrase is the Ed25519 seed. It is public on purpose, and a key signed
/// with it activates only in a Debug build. `LicenseKeysTests` pins that what this signs is what
/// `LicenseVerifier.test` accepts, so the two derivations can't drift apart unnoticed.
enum TestLicenseKeys {
    static func privateKey() throws -> Curve25519.Signing.PrivateKey {
        let seed = SHA256.hash(data: Data("Dirnex license TEST key. Public on purpose.".utf8))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(seed))
    }

    /// A `dnx1` key for `name`, covering releases up to `until`.
    static func key(
        to name: String = "Jane Appleseed",
        until: String = "2027-09-29",
        issued: String = "2026-09-29",
        id: String = "5RSU7LEVTH3C46PCOBVL54R57M"
    ) throws -> String {
        let payload = try JSONSerialization.data(
            withJSONObject: ["v": 1, "id": id, "to": name, "issued": issued, "until": until],
            options: [.sortedKeys]
        )
        let message = "dnx1." + base64URL(payload)
        let signature = try privateKey().signature(for: Data(message.utf8))
        return message + "." + base64URL(signature)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
