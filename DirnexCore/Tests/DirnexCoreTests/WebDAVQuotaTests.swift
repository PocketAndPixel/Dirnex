import Foundation
import Testing

@testable import DirnexCore

/// The space a WebDAV server says is left (RFC 4331, PLAN.md §M38 Slice 7). Every answer here was
/// captured on 2026-11-10 through ``WebDAVProcessArguments/quotaPropfind(session:backendPath:)``'s
/// own arguments: from Nextcloud 34.0.5 in a container, each after a restart so its five-minute cache
/// held nothing, and from the two Apaches in `scripts/live_test_servers.sh`, macOS's 2.4.67 and the
/// Kerberos stand-in's Debian 2.4.68. Session cookies are removed from the headers.
///
/// The Nextcloud account holds two 3 MB files, one at its root and one in `sub`.
@Suite("WebDAV quota")
struct WebDAVQuotaTests {
    static let account = WebDAVLocation(
        host: "127.0.0.1",
        port: 8099,
        username: "probe",
        usesTLS: false,
        rootPath: "/remote.php/dav/files/probe"
    )
    /// A root saved below the account's own.
    static let subfolder = WebDAVLocation(
        host: "127.0.0.1",
        port: 8099,
        username: "probe",
        usesTLS: false,
        rootPath: "/remote.php/dav/files/probe/sub"
    )
    static let apache = WebDAVLocation(
        host: "127.0.0.1",
        port: 8088,
        username: "probe",
        usesTLS: false,
        rootPath: "/basic"
    )
    static let debian = WebDAVLocation(
        host: "localhost",
        port: 8091,
        username: "",
        usesTLS: false,
        rootPath: "/negotiate"
    )

    /// 200 MiB, the quota the account had, less the 6 000 000 bytes it held.
    static let spaceLeft: Int64 = 209_715_200 - 6_000_000

    private static func nextcloud(_ name: String) throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run("curl-exit0-nextcloud-\(name)", body: "nextcloud-\(name)")
    }

    private func quota(_ response: WebDAVHTTPResponse, at location: WebDAVLocation) -> WebDAVQuota? {
        WebDAVQuota(response, folder: location.serverPath(forBackendPath: "/"))
    }

    /// The account root's real answer with its number replaced, for the values no server here could
    /// be made to send.
    private func accountAnswer(withNumber number: String) throws -> WebDAVHTTPResponse {
        let text = try WebDAVFixtures.text("nextcloud-quota-root-207")
        let real = ">\(Self.spaceLeft)<"
        #expect(text.contains(real))
        return WebDAVHTTPResponse(
            status: 207,
            body: Data(text.replacingOccurrences(of: real, with: ">\(number)<").utf8)
        )
    }

    // MARK: - The request

    @Test(
        "a quota request is one Depth 0 PROPFIND of the folder, with its slash, for the space left alone"
    )
    func request() throws {
        let session = WebDAVSession(location: Self.account)
        let arguments = WebDAVProcessArguments.quotaPropfind(session: session, backendPath: "/")
        #expect(arguments.first == "-q")
        let method = try #require(arguments.firstIndex(of: "-X"))
        #expect(arguments[method + 1] == "PROPFIND")
        #expect(arguments.contains("Depth: 0"))
        #expect(arguments.last == "http://127.0.0.1:8099/remote.php/dav/files/probe/")
        let body = try #require(arguments.firstIndex(of: "--data-binary").map { arguments[$0 + 1] })
        #expect(body.contains("<D:quota-available-bytes/>"))
        // The used figure is a folder's size on Nextcloud, so nothing could show it honestly.
        #expect(!body.contains("quota-used-bytes"))
        #expect(!body.contains("getcontentlength") && !body.contains("allprop"))
    }

    @Test("its credentials go to stdin as every other request's do")
    func requestCredentials() {
        let arguments = WebDAVProcessArguments.quotaPropfind(
            session: WebDAVSession(location: Self.account),
            backendPath: "/"
        )
        #expect(arguments.contains("--basic"))
        #expect(arguments.indices.contains { arguments[$0] == "-K" && arguments[$0 + 1] == "-" })
        #expect(!arguments.contains { $0.contains("probe:") })

        let ticket = WebDAVProcessArguments.quotaPropfind(
            session: WebDAVSession(location: Self.debian, authentication: .negotiate),
            backendPath: "/"
        )
        #expect(!ticket.contains("-K"))
        #expect(ticket.contains("--negotiate"))
    }

    // MARK: - Reading the answer

    @Test("Nextcloud's account root answers the space left")
    func accountRoot() throws {
        let response = try Self.nextcloud("quota-root-207")
        #expect(response.status == 207)
        #expect(quota(response, at: Self.account) == WebDAVQuota(availableBytes: Self.spaceLeft))
    }

    @Test("a root saved below the account's answers the account's space, not the folder's")
    func subfolderRoot() throws {
        let response = try Self.nextcloud("quota-subfolder-207")
        #expect(try WebDAVFixtures.text("nextcloud-quota-subfolder-207").contains("/probe/sub/"))
        #expect(quota(response, at: Self.subfolder) == WebDAVQuota(availableBytes: Self.spaceLeft))
    }

    @Test("an account with no quota is no quota, not an empty disk")
    func unlimited() throws {
        #expect(try WebDAVFixtures.text("nextcloud-quota-unlimited-207").contains(">-3<"))
        #expect(quota(try Self.nextcloud("quota-unlimited-207"), at: Self.account) == nil)
    }

    @Test("a full account is zero bytes left, which is a quota to show")
    func full() throws {
        #expect(
            quota(try Self.nextcloud("quota-full-207"), at: Self.account)
                == WebDAVQuota(availableBytes: 0)
        )
    }

    @Test("Apache answers the property 404, on macOS and on Debian, and that is no quota")
    func apache() throws {
        for (family, location) in [("apache", Self.apache), ("kerberos", Self.debian)] {
            let response = try WebDAVFixtures.run(
                "curl-exit0-\(family)-quota-404",
                body: "\(family)-quota-404"
            )
            #expect(response.status == 207)
            #expect(try WebDAVFixtures.text("\(family)-quota-404").contains("404 Not Found"))
            #expect(quota(response, at: location) == nil)
        }
    }

    @Test("a refusal is no quota")
    func refused() throws {
        let response = try Self.nextcloud("quota-401")
        #expect(response.status == 401)
        #expect(quota(response, at: Self.account) == nil)
    }

    @Test("sabre's other codes, an empty element and a number too big for Int64 are no number")
    func noNumber() throws {
        for number in ["-1", "-2", "", "99999999999999999999", "1.5e9"] {
            #expect(
                quota(try accountAnswer(withNumber: number), at: Self.account) == nil,
                "\(number)"
            )
        }
        #expect(
            quota(try accountAnswer(withNumber: "1"), at: Self.account)
                == WebDAVQuota(availableBytes: 1)
        )
    }

    @Test("a body that is not a multistatus is no quota")
    func notAMultistatus() throws {
        let page = try WebDAVFixtures.data("nas-missing-404", extension: "html")
        #expect(quota(WebDAVHTTPResponse(status: 207, body: page), at: Self.account) == nil)
    }

    @Test("a listing's rows never carry a quota, since a listing does not name one")
    func listingsCarryNone() throws {
        let rows = try WebDAVFixtures.parse("nextcloud-folder-props").responses
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.quotaAvailableBytes == nil })
    }

    // MARK: - The backend

    @Test("the backend asks once, of its root, and reads the answer")
    func backendAsksTheRoot() throws {
        let transport = FakeWebDAVTransport()
        transport.quotaAnswer = { _ in try Self.nextcloud("quota-root-207") }
        let backend = WebDAVBackend(location: Self.account, transport: transport)

        #expect(try backend.quota() == WebDAVQuota(availableBytes: Self.spaceLeft))
        #expect(transport.quotaRequests == ["/"])
        #expect(transport.propfinds.isEmpty)
    }

    @Test("a request that got no answer throws, so a caller can keep what it last heard")
    func transportFailureThrows() {
        let transport = FakeWebDAVTransport()
        transport.quotaAnswer = { _ in try WebDAVFixtures.run("curl-exit28-unreachable") }
        let backend = WebDAVBackend(location: Self.account, transport: transport)
        #expect(throws: WebDAVResponseError.transport(.operationTimedOut)) { try backend.quota() }
    }

    // MARK: - When to ask again

    @Test("a listing asks again five minutes after the last ask, and at once if the clock went back")
    func schedule() {
        let asked = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(WebDAVQuota.isDue(lastAsked: nil, now: asked))
        #expect(!WebDAVQuota.isDue(lastAsked: asked, now: asked))
        #expect(!WebDAVQuota.isDue(lastAsked: asked, now: asked.addingTimeInterval(299)))
        #expect(WebDAVQuota.isDue(lastAsked: asked, now: asked.addingTimeInterval(300)))
        #expect(WebDAVQuota.isDue(lastAsked: asked, now: asked.addingTimeInterval(-1)))
    }
}
