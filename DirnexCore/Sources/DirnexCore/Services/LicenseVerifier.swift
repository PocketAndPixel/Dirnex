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
