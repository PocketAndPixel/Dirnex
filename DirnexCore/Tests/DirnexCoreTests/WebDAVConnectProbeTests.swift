import Foundation
import Testing

@testable import DirnexCore

/// Reading a `WWW-Authenticate` challenge for its schemes (PLAN.md §M32 Slice 2).
@Suite("WebDAVChallenge")
struct WebDAVChallengeTests {
    @Test("a challenge's parameters are not schemes, whatever they contain")
    func parametersAreNotSchemes() {
        // The NAS's, Nextcloud's, and the local Apache's Digest, whose nonce ends in `=` and whose
        // qop may hold a comma inside its quotes.
        #expect(WebDAVChallenge.schemes(in: [#"Basic realm="SYNO_WebDAV Storage""#]) == ["basic"])
        #expect(
            WebDAVChallenge.schemes(in: [#"Basic realm="Nextcloud", charset="UTF-8""#]) == ["basic"]
        )
        #expect(WebDAVChallenge.schemes(in: [
            #"Digest realm="dirnex-digest", nonce="woSAZXReBgA=fb4d", algorithm=MD5, qop="auth,auth-int""#
        ]) == ["digest"])
        #expect(WebDAVChallenge.schemes(in: [#"Basic realm = "spaced""#]) == ["basic"])
    }

    @Test("several challenges in one header, or in several, are all read")
    func severalChallenges() {
        #expect(WebDAVChallenge.schemes(in: [
            #"Basic realm="a, b", Digest realm="c", nonce="x=,y""#
        ]) == ["basic", "digest"])
        #expect(WebDAVChallenge.schemes(in: ["Negotiate", "NTLM", #"Basic realm="dirnex-multi""#])
            == ["negotiate", "ntlm", "basic"])
    }

    /// A realm is free text, so a comma and a word inside its quotes look exactly like the next
    /// challenge to a reader that splits without them — and an escaped quote must not end them.
    @Test("a comma inside a quoted value, escaped quotes and all, starts no challenge")
    func quotedCommas() {
        #expect(WebDAVChallenge.schemes(in: [#"Basic realm="Files, Digest area", Bearer"#])
            == ["basic", "bearer"])
        #expect(WebDAVChallenge.schemes(in: [#"Basic realm="say \"hi, Digest x\" now", Bearer"#])
            == ["basic", "bearer"])
    }

    @Test("a token68 credential follows its scheme, and case does not matter")
    func token68AndCase() {
        #expect(WebDAVChallenge.schemes(in: ["Negotiate YIIBhwYGKwYBBQUCoII="]) == ["negotiate"])
        #expect(WebDAVChallenge.schemes(in: [#"BASIC realm="x""#]) == ["basic"])
        #expect(WebDAVChallenge.schemes(in: []).isEmpty)
        #expect(WebDAVChallenge.schemes(in: [""]).isEmpty)
    }

    @Test("Basic over HTTPS, Digest over plain HTTP, when both are offered")
    func preference() {
        let both = ["basic", "digest"]
        #expect(WebDAVChallenge.preferred(among: both, overTLS: true) == .basic)
        #expect(WebDAVChallenge.preferred(among: both, overTLS: false) == .digest)
        #expect(WebDAVChallenge.preferred(among: ["basic"], overTLS: false) == .basic)
        #expect(WebDAVChallenge.preferred(among: ["digest"], overTLS: true) == .digest)
        #expect(WebDAVChallenge.preferred(among: ["negotiate", "ntlm"], overTLS: true) == nil)
    }
}

/// The connect probe (PLAN.md §M32 Slice 2), against the challenges and answers real servers sent.
@Suite("WebDAVConnectProbe")
struct WebDAVConnectProbeTests {
    private static let nas = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let plainHTTP = WebDAVLocation(
        host: "127.0.0.1",
        port: 8089,
        username: "tester",
        usesTLS: false
    )
    private static let anonymous = WebDAVLocation(
        host: "127.0.0.1",
        port: 8089,
        username: "",
        usesTLS: false
    )

    private func connect(_ location: WebDAVLocation, _ server: FakeWebDAVServer) throws -> WebDAVConnection {
        try WebDAVConnectProbe.connect(to: location, over: server.transport)
    }

    private static func challenge(_ value: String) -> WebDAVHTTPResponse {
        WebDAVHTTPResponse(status: 401, headers: ["WWW-Authenticate": [value]])
    }

    @Test("the NAS: asked with nothing, it names Basic, and Basic opens its root")
    func nasConnects() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-nas-propfind-401") }
        server.answers[.basic] = { _ in
            try WebDAVFixtures.run("curl-exit0-nas-propfind-207", body: "nas-root-depth0-props")
        }
        #expect(try connect(Self.nas, server) == WebDAVConnection(authentication: .basic))
        #expect(server.asked == [nil, .basic])
        #expect(
            server.requests.allSatisfy { $0 == .init(path: "/", depth: .zero, isCollection: true) }
        )
    }

    @Test("a server that asks for Digest gets Digest, and no password went out before it asked")
    func digestServer() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-apache-digest-401") }
        server.answers[.digest] = { _ in try WebDAVFixtures.multistatus("nas-root-depth0-props") }
        #expect(try connect(Self.plainHTTP, server) == WebDAVConnection(authentication: .digest))
        #expect(server.asked == [nil, .digest])
    }

    @Test("Basic found behind Negotiate and NTLM is still Basic")
    func basicAmongOthers() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-apache-multi-401") }
        server.answers[.basic] = { _ in try WebDAVFixtures.multistatus("nas-root-depth0-props") }
        #expect(try connect(Self.plainHTTP, server).authentication == .basic)
    }

    @Test("a server offering both gets Digest over plain HTTP and Basic over HTTPS")
    func bothOffered() throws {
        let both = #"Basic realm="x", Digest realm="x", nonce="n=""#
        for (location, expected) in [(Self.plainHTTP, WebDAVAuthScheme.digest), (Self.nas, .basic)] {
            let server = FakeWebDAVServer()
            server.answers[nil] = { _ in Self.challenge(both) }
            server.answers[expected] = { _ in try WebDAVFixtures.multistatus("nas-root-depth0-props") }
            #expect(try connect(location, server).authentication == expected)
        }
    }

    @Test("schemes Dirnex does not speak are named, and nothing is sent in them")
    func unsupportedSchemes() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in Self.challenge("Negotiate, NTLM") }
        #expect(throws: WebDAVConnectError.unsupportedAuthentication(schemes: ["negotiate", "ntlm"])) {
            try connect(Self.nas, server)
        }
        #expect(server.asked == [nil])
    }

    @Test("an account without a name, asked for credentials, is told so")
    func credentialsRequired() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-apache-digest-401") }
        #expect(throws: WebDAVConnectError.credentialsRequired) { try connect(Self.anonymous, server) }
    }

    @Test("a public folder opens for an account without a name, in one request")
    func publicFolder() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-apache-public-207",
                body: "apache-public-depth0-props"
            )
        }
        let publicRoot = WebDAVLocation(
            host: "127.0.0.1",
            port: 8089,
            username: "",
            usesTLS: false,
            rootPath: "/public"
        )
        #expect(try connect(publicRoot, server) == WebDAVConnection(authentication: nil))
        #expect(server.asked == [nil])
    }

    @Test("an account still logs in where reads are public, in Digest if that is all it is offered")
    func publicReadsStillLogIn() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.multistatus("nas-root-depth0-props") }
        server.answers[.basic] = { _ in try WebDAVFixtures.run("curl-exit0-apache-digest-401") }
        server.answers[.digest] = { _ in try WebDAVFixtures.multistatus("nas-root-depth0-props") }
        #expect(try connect(Self.plainHTTP, server).authentication == .digest)
        #expect(server.asked == [nil, .basic, .digest])
    }

    @Test("credentials refused in the scheme the server named are refused, with no second try")
    func credentialsRefused() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-nas-propfind-401") }
        server.answers[.basic] = { _ in try WebDAVFixtures.run("curl-exit0-nas-propfind-401") }
        #expect(throws: WebDAVConnectError.credentialsRefused) { try connect(Self.nas, server) }
        #expect(server.asked == [nil, .basic])
    }

    @Test("a folder without WebDAV answers 405, and a web page 200: neither is WebDAV")
    func notWebDAV() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-apache-nodav-405") }
        #expect(throws: WebDAVConnectError.notWebDAV(status: 405)) { try connect(
            Self.plainHTTP,
            server
        ) }

        server.answers[nil] = { _ in WebDAVHTTPResponse(status: 200, body: Data("<html>".utf8)) }
        #expect(throws: WebDAVConnectError.notWebDAV(status: 200)) { try connect(
            Self.plainHTTP,
            server
        ) }
    }

    @Test("a redirect is reported with where it points, not followed")
    func redirect() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-apache-redirect-301") }
        #expect(throws: WebDAVConnectError.redirected(location: "http://127.0.0.1:8089/public//")) {
            try connect(Self.plainHTTP, server)
        }
    }

    @Test("a root that is not there, or is a file, ends the connect by name")
    func rootProblems() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-nas-propfind-401") }
        server.answers[.basic] = { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: WebDAVConnectError.rootNotFound) { try connect(Self.nas, server) }

        let fileRoot = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home/dirnex-webdav-fixture/Привет мир.txt"
        )
        // Some servers answer a file named as a collection with the file.
        server.answers[.basic] = { _ in try WebDAVFixtures.multistatus("nas-file-depth0-props") }
        #expect(throws: WebDAVConnectError.rootIsNotAFolder) { try connect(fileRoot, server) }
    }

    /// What Apache really does, and what the first version of this test did not feed: the root asked
    /// for as a collection is a bare 400 when it is a file, and only the same request without the
    /// slash says what is there. Caught by a live run against macOS's Apache, not by this suite.
    @Test("a file root answered with Apache's 400 is found by asking again without the slash")
    func fileRootBehindA400() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-nas-propfind-401") }
        server.answers[.basic] = { request in
            request.isCollection
                ? try WebDAVFixtures.run(
                    "curl-exit0-nas-propfind-file-slash-400",
                    body: "nas-file-as-collection-400",
                    bodyExtension: "html"
                )
                : try WebDAVFixtures.multistatus("nas-file-depth0-props")
        }
        let fileRoot = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home/dirnex-webdav-fixture/Привет мир.txt"
        )
        #expect(throws: WebDAVConnectError.rootIsNotAFolder) { try connect(fileRoot, server) }
        #expect(server.requests.map(\.isCollection) == [true, true, false])
    }

    @Test("a 400 for a root that is a folder after all stays the refusal it was")
    func folderRootBehindA400() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { request in
            request.isCollection
                ? WebDAVHTTPResponse(status: 400)
                : try WebDAVFixtures.multistatus("nas-root-depth0-props")
        }
        #expect(
            throws: WebDAVConnectError.refused(WebDAVServiceError(status: 400, method: .propfind))
        ) {
            try connect(Self.nas, server)
        }
    }

    @Test("an untrusted certificate is the transport's exit 60, for the trust sheet")
    func untrustedCertificate() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit60-nas-https-untrusted") }
        #expect(throws: WebDAVConnectError.transport(.certificateNotTrusted)) { try connect(
            Self.nas,
            server
        ) }
    }

    @Test("any other refusal is reported with its status")
    func otherRefusal() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in WebDAVHTTPResponse(status: 403) }
        #expect(
            throws: WebDAVConnectError.refused(WebDAVServiceError(status: 403, method: .propfind))
        ) {
            try connect(Self.nas, server)
        }
    }
}
