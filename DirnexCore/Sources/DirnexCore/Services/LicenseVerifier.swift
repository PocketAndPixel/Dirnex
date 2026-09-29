import CryptoKit
import Foundation

/// Checks license keys against the public key a Dirnex build carries (PLAN.md §M29).
///
/// Offline, always: there's no server to ask and no activation count, so a key works on every Mac of
/// the person it names, whether or not the store is up. The public key is injected. The app passes
/// the production one, and the tests pass the throwaway test key the shared vectors are signed with.
public struct LicenseVerifier: Sendable {
    /// Public keys are written `dnx1-public-` and 43 base64url characters. The private half carries
    /// `dnx1-private-`, so the two can't be mixed up, and pasting the private one here, which would
    /// publish it in this open-source repo, fails at once rather than quietly.
    public static let publicKeyPrefix = "dnx1-public-"

    public struct InvalidPublicKey: Error, Equatable {}

    /// The public half of the key the store signs licenses with (generated 2026-09-29). The private
    /// half exists only in Oleg's password manager and in the store's server.
    public static let productionPublicKey = "dnx1-public-wOrqllZ8Y0mgB9frtk0vJRFgH032J6BiqE7wQ62Hw-0"

    /// The throwaway test key the shared vectors are signed with. Its private half is public (the
    /// signer derives it from a fixed phrase), so a key signed with it proves nothing: only a Debug
    /// build accepts it, which is the app's decision, not this type's.
    public static let testPublicKey = "dnx1-public-8BfevcdnSDxaqWjDbkP64cZjnpYplZd4v4rj9AIrG5U"

    /// The verifier for real licenses.
    public static var production: LicenseVerifier {
        failingClosed(productionPublicKey)
    }

    /// The verifier for keys signed with the test key.
    public static var test: LicenseVerifier {
        failingClosed(testPublicKey)
    }

    /// A verifier for one of the constants above. If a constant were ever malformed, every key
    /// would be refused rather than the app trapping at launch; `LicenseKeyTests` pins that both
    /// parse, so the fallback is never what runs.
    private static func failingClosed(_ publicKey: String) -> LicenseVerifier {
        (try? LicenseVerifier(publicKey: publicKey)) ?? LicenseVerifier { _, _ in false }
    }

    private let isValidSignature: @Sendable (_ signature: Data, _ message: Data) -> Bool

    public init(publicKey text: String) throws {
        guard text.hasPrefix(Self.publicKeyPrefix),
              let raw = Base64URL.decode(String(text.dropFirst(Self.publicKeyPrefix.count))),
              raw.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
        else {
            throw InvalidPublicKey()
        }
        isValidSignature = { signature, message in key.isValidSignature(signature, for: message) }
    }

    /// A verifier with its signature check replaced. For the tests' negative control only: it
    /// proves the vectors fail a checker that skips the signature.
    init(signatureCheck: @escaping @Sendable (_ signature: Data, _ message: Data) -> Bool) {
        isValidSignature = signatureCheck
    }

    /// Checks pasted text: whitespace is removed, then size, prefix, shape, **the signature**, and
    /// only then the payload. The signer runs the same steps in the same order, so both give the
    /// same answer for the same text. Never throws and never traps, whatever the text.
    public func check(_ pasted: String) -> Result<LicenseKey, LicenseKeyError> {
        LicenseKey.envelope(of: pasted).flatMap { envelope in
            guard isValidSignature(envelope.signature, envelope.signedMessage) else {
                return .failure(.badSignature)
            }
            return LicenseKey.decode(envelope)
        }
    }
}
