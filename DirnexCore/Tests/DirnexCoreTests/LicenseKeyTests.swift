import Foundation
import Testing

@testable import DirnexCore

/// What the shared vectors don't reach: the verifier's public key, pasting, hostile text, and the
/// base64url codec on its own.
@Suite("License key")
struct LicenseKeyTests {
    private func verifier() throws -> LicenseVerifier {
        try LicenseVerifier(publicKey: #require(LicenseVectorFile.shared).publicKey)
    }

    private func validKey() throws -> String {
        try #require(LicenseVectorFile.shared?.vectors.first { $0.name == "valid" }).input
    }

    // MARK: - The public key

    @Test("the verifier takes only a prefixed 32-byte public key")
    func publicKeyShape() throws {
        let publicKey = try #require(LicenseVectorFile.shared).publicKey
        let raw = String(publicKey.dropFirst(LicenseVerifier.publicKeyPrefix.count))
        #expect(throws: Never.self) { try LicenseVerifier(publicKey: publicKey) }
        for bad in [raw, "dnx1-private-" + raw, publicKey + "AA", String(publicKey.dropLast(2)), ""] {
            #expect(throws: LicenseVerifier.InvalidPublicKey.self, "\(bad)") {
                try LicenseVerifier(publicKey: bad)
            }
        }
    }

    @Test("a key checked against another public key is refused for its signature")
    func otherPublicKey() throws {
        let other = try LicenseVerifier(publicKey: "dnx1-public-" + Base64URL.encode(Data(
            repeating: 7,
            count: 32
        )))
        #expect(try other.check(validKey()) == .failure(.badSignature))
    }

    // MARK: - Pasting

    @Test("the key's text is kept without the whitespace it was pasted with")
    func keepsNormalizedText() throws {
        let key = try validKey()
        let pasted = "\n  " + key.prefix(40) + "\r\n" + key.dropFirst(40) + " \t"
        let checked = try verifier().check(pasted).get()
        #expect(checked.text == key)
        #expect(checked.licensee == "Jane Appleseed")
    }

    @Test("only the invisible characters are removed, and a CRLF goes as a whole")
    func normalizes() {
        #expect(
            LicenseKey.normalized(" dnx1.\r\nab\u{A0}c\u{200B}d\u{AD}\u{FEFF}\u{85}\t") == "dnx1.abcd"
        )
        #expect(LicenseKey.normalized("dnx1.a>b") == "dnx1.a>b")
        // A combining mark stays, so the text is refused rather than silently repaired.
        #expect(LicenseKey.normalized("dnx1.\u{301}a") == "dnx1.\u{301}a")
    }

    @Test("a combining mark after the prefix is judged on bytes, as the signer judges it")
    func combiningMarkAfterPrefix() throws {
        // As a `String`, "dnx1." followed by U+0301 doesn't have the prefix "dnx1." (the mark
        // joins the dot). The signer compares code units and says malformed; so must the app.
        let key = try validKey()
        let marked = "dnx1.\u{301}" + key.dropFirst(5)
        #expect(try verifier().check(marked) == .failure(.malformed))
    }

    // MARK: - Hostile text

    @Test("hostile text is refused without trapping")
    func hostileText() throws {
        let verifier = try verifier()
        let cases: [(String, LicenseKeyError)] = [
            ("", .empty),
            (String(repeating: " ", count: 100_000), .empty),
            (String(repeating: "A", count: 2_000_000), .tooLong),
            ("dnx1." + String(repeating: "é", count: 600), .tooLong),
            ("dnx1.", .malformed),
            ("dnx1..", .malformed),
            ("dnx1.....", .malformed),
            ("dnx1.\u{0}.\u{0}", .malformed),
            ("dnx1.🙂.🙂", .malformed),
            ("dnx", .wrongPrefix),
            ("dnx.", .wrongPrefix),
            ("dnxA.", .wrongPrefix),
            ("dnx12", .wrongPrefix),
            ("dnx12.", .unsupportedVersion),
            ("dnx0.x.y", .unsupportedVersion),
            ("https://dirnex.app/activate#dnx1.x.y", .wrongPrefix)
        ]
        for (text, expected) in cases {
            #expect(verifier.check(text) == .failure(expected), "\(text.prefix(40))")
        }
    }

    @Test("random text after the prefix is never a valid key")
    func randomText() throws {
        let verifier = try verifier()
        // Mostly base64url and dots, so many inputs get as far as the signature check, with any
        // Unicode scalar mixed in.
        let likely = Array(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.".unicodeScalars
        )
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            var text = String.UnicodeScalarView("dnx1.".unicodeScalars)
            for _ in 0..<Int.random(in: 0..<400, using: &generator) {
                if Int.random(in: 0..<10, using: &generator) < 8, let scalar = likely.randomElement(
                    using: &generator
                ) {
                    text.append(scalar)
                } else if let scalar = Unicode.Scalar(
                    UInt32.random(in: 0...0x10FFFF, using: &generator)
                ) {
                    text.append(scalar)
                }
            }
            #expect(throws: LicenseKeyError.self) { try verifier.check(String(text)).get() }
        }
    }

    // MARK: - base64url

    @Test("base64url round-trips every length, and agrees with Foundation's base64")
    func base64URLRoundTrip() {
        for length in 0..<70 {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * 37 + length) })
            let text = Base64URL.encode(data)
            #expect(Base64URL.decode(text) == data)
            let foundation = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            #expect(text == foundation)
        }
    }

    @Test("base64url refuses padding, the standard alphabet, a lone character and loose bits")
    func base64URLRefusals() {
        for text in ["YWJj=", "YW+j", "YW/j", "Y", "YWJjZ", "YWJ j", "ab!!cd", "QR"] {
            #expect(Base64URL.decode(text) == nil, "\(text)")
        }
        #expect(Base64URL.decode("QQ") == Data([0x41]))
        #expect(Base64URL.decode("") == Data())
    }
}
