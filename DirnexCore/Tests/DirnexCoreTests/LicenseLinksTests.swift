import Foundation
import Testing

@testable import DirnexCore

@Suite("License links")
struct LicenseLinksTests {
    private func validKey() throws -> String {
        try #require(LicenseVectorFile.shared?.vectors.first { $0.name == "valid" }).input
    }

    // MARK: - dirnex://license?key=…

    @Test("the activation link carries the key")
    func readsActivationLink() throws {
        let key = try validKey()
        let url = try #require(URL(string: "dirnex://license?key=\(key)"))
        #expect(LicenseLinks.keyText(in: url) == key)
    }

    @Test("scheme and host are case-insensitive, and a trailing slash is fine")
    func toleratesSpelling() throws {
        for link in ["DIRNEX://LICENSE?key=abc", "dirnex://License/?key=abc"] {
            let url = try #require(URL(string: link))
            #expect(LicenseLinks.keyText(in: url) == "abc", "\(link)")
        }
    }

    @Test("anything else is not the activation link")
    func refusesOtherLinks() throws {
        for link in [
            "https://dirnex.app/license?key=abc",
            "dirnex://settings?key=abc",
            "dirnex://license/other?key=abc",
            "dirnex://license?code=abc",
            "dirnex://license?key=",
            "dirnex://license?key=abc&key=def",
            "dirnex:license?key=abc",
            "file:///Users/jane/license.txt"
        ] {
            let url = try #require(URL(string: link))
            #expect(LicenseLinks.keyText(in: url) == nil, "\(link)")
        }
    }

    // MARK: - Pasting a link instead of a key

    @Test("a pasted activation link, either kind, yields its key")
    func pastedLinks() throws {
        let key = try validKey()
        #expect(LicenseLinks.keyText(fromPasted: "dirnex://license?key=\(key)") == key)
        #expect(LicenseLinks.keyText(fromPasted: "https://dirnex.app/activate#\(key)") == key)
        #expect(LicenseLinks.keyText(fromPasted: "https://www.dirnex.app/activate#\(key)") == key)
    }

    @Test("a link wrapped across lines by a mail client still yields its key")
    func wrappedLink() throws {
        let key = try validKey()
        let pasted = "https://dirnex.app/activate#\(key.prefix(60))\r\n\(key.dropFirst(60))\n"
        #expect(LicenseLinks.keyText(fromPasted: pasted) == key)
    }

    @Test("a pasted key, or anything that isn't one of the two links, comes back unchanged")
    func otherTextUnchanged() throws {
        let key = try validKey()
        for text in [
            key,
            "  \(key)\n",
            "https://evil.example/activate#\(key)",
            "https://dirnex.app/buy",
            "hello"
        ] {
            #expect(LicenseLinks.keyText(fromPasted: text) == text, "\(text.prefix(30))")
        }
    }

    @Test("the key from a pasted link checks out")
    func pastedLinkVerifies() throws {
        let key = try validKey()
        let text = LicenseLinks.keyText(fromPasted: "https://dirnex.app/activate#\(key)")
        let verifier = try LicenseVerifier(publicKey: #require(LicenseVectorFile.shared).publicKey)
        #expect(try verifier.check(text).get().licensee == "Jane Appleseed")
    }

    // MARK: - The store

    @Test("buying goes to the store's buy page")
    func buy() {
        #expect(LicenseLinks.buy.absoluteString == "https://dirnex.app/buy")
    }

    @Test("renewing names the license by its id alone, never by name")
    func renew() {
        let key = LicenseKey(
            text: "dnx1.test",
            id: "5RSU7LEVTH3C46PCOBVL54R57M",
            licensee: "Jane Appleseed <jane@example.com>",
            issued: LicenseDay(year: 2026, month: 9, day: 29),
            until: LicenseDay(year: 2027, month: 9, day: 29)
        )
        let url = LicenseLinks.renew(key)
        #expect(url.absoluteString == "https://dirnex.app/renew?license=5RSU7LEVTH3C46PCOBVL54R57M")
        #expect(!url.absoluteString.contains("Jane"))
        #expect(!url.absoluteString.contains("example"))
    }

    // MARK: - The keys a build carries

    @Test("both public keys the app carries parse")
    func carriedKeysParse() {
        #expect(throws: Never.self) { try LicenseVerifier(
            publicKey: LicenseVerifier.productionPublicKey
        ) }
        #expect(throws: Never.self) { try LicenseVerifier(publicKey: LicenseVerifier.testPublicKey) }
    }

    @Test("the test key is the one the shared vectors are signed with")
    func testKeyMatchesVectors() throws {
        #expect(try #require(LicenseVectorFile.shared).publicKey == LicenseVerifier.testPublicKey)
    }

    @Test("the production verifier refuses a test-signed key, and the test verifier accepts it")
    func productionRefusesTestKeys() throws {
        let key = try validKey()
        #expect(LicenseVerifier.production.check(key) == .failure(.badSignature))
        #expect(try LicenseVerifier.test.check(key).get().licensee == "Jane Appleseed")
    }

    @Test("the licensing commands are real registry commands")
    func licensingCommandsExist() {
        let ids = Set(CommandCatalog.all.map(\.id))
        #expect(CommandCatalog.licensingCommandIDs.isSubset(of: ids))
        #expect(CommandCatalog.licensingCommandIDs == ["app.license", "app.buyLicense"])
    }
}
