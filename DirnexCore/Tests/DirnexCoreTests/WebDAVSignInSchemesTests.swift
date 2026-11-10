import Foundation
import Testing

@testable import DirnexCore

/// NTLM and Negotiate (PLAN.md §M38 Slice 6): how each is spelled to `curl`, and what the connect
/// probe makes of the challenges that ask for them.
///
/// The fixtures are real runs of these builders through `curl` 8.7.1 on 2026-11-10, against the two
/// stand-ins PLAN.md §M38 decided on: `Tooling/fake-ntlm-proxy.py`, which verifies the NTLMv2 proof
/// as a domain controller does and offers `Negotiate` and `NTLM` as IIS does by default, and
/// `Tooling/negotiate-standin`, an MIT KDC with Apache's `mod_auth_gssapi`. No real IIS or Active
/// Directory was involved.
@Suite("WebDAV NTLM and Negotiate: the arguments")
struct WebDAVSignInArgumentsTests {
    private static let ntlm = WebDAVLocation(
        host: "127.0.0.1",
        port: 8090,
        username: #"DIRNEX\probe"#,
        usesTLS: false,
        rootPath: "/ntlm"
    )
    private static let kerberos = WebDAVLocation(
        host: "localhost",
        port: 8091,
        username: "",
        usesTLS: false,
        rootPath: "/negotiate"
    )
    private static let password = "pr0be:pass"

    private static func session(
        _ location: WebDAVLocation,
        _ scheme: WebDAVAuthScheme?
    ) -> WebDAVSession {
        WebDAVSession(location: location, authentication: scheme)
    }

    /// Every single-request builder, so a scheme spelled wrongly in any one of them fails here.
    private static func everyRequest(_ session: WebDAVSession) -> [String: [String]] {
        [
            "propfind": WebDAVProcessArguments.propfind(
                session: session,
                backendPath: "/a",
                depth: .one,
                isCollection: true
            ),
            "download": WebDAVProcessArguments.download(
                session: session,
                backendPath: "/a.bin",
                localPath: "/scratch/a.bin",
                resume: true
            ),
            "mkcol": WebDAVProcessArguments.mkcol(session: session, backendPath: "/new"),
            "upload": WebDAVProcessArguments.upload(
                session: session,
                localPath: "/scratch/a.bin",
                backendPath: "/a.bin",
                condition: .ifAbsent
            ),
            "putEmpty": WebDAVProcessArguments.putEmpty(session: session, backendPath: "/e.txt"),
            "move": WebDAVProcessArguments.move(session: session, backendPath: "/a", to: "/b"),
            "copy": WebDAVProcessArguments.copy(session: session, backendPath: "/a", to: "/b"),
            "delete": WebDAVProcessArguments.delete(session: session, backendPath: "/a")
        ]
    }

    private static func sections(_ configuration: String) -> [[String]] {
        configuration.components(separatedBy: "next\n").map {
            $0.split(separator: "\n").map(String.init)
        }
    }

    @Test("NTLM is asked for by name, with the password on stdin and the account nowhere in argv")
    func ntlmOnStdin() {
        let session = Self.session(Self.ntlm, .ntlm)
        #expect(session.sendsCredentials)
        #expect(!session.signsInWithTicket)
        for (verb, arguments) in Self.everyRequest(session) {
            #expect(arguments.contains("--ntlm"), "\(verb)")
            #expect(!arguments.contains("--basic") && !arguments.contains("--digest"), "\(verb)")
            #expect(
                arguments.indices.contains { arguments[$0] == "-K" && arguments[$0 + 1] == "-" },
                "\(verb)"
            )
            #expect(!arguments.contains("-u") && !arguments.contains("--negotiate"), "\(verb)")
            #expect(!arguments.contains { $0.contains("probe") || $0.contains("DIRNEX") }, "\(verb)")
        }
    }

    /// Negotiate's `-u :` is `curl`'s switch for the authentication code and carries nothing, so it
    /// may sit in argv; there is no password, so nothing goes to stdin and `-K -` would wait on it.
    @Test("Negotiate is --negotiate -u : in argv, with nothing on stdin")
    func negotiateInArgv() throws {
        let session = Self.session(Self.kerberos, .negotiate)
        #expect(!session.sendsCredentials)
        #expect(session.signsInWithTicket)
        for (verb, arguments) in Self.everyRequest(session) {
            let index = try #require(arguments.firstIndex(of: "--negotiate"), "\(verb)")
            #expect(arguments[index + 1] == "-u" && arguments[index + 2] == ":", "\(verb)")
            #expect(!arguments.contains("-K"), "\(verb)")
            #expect(
                !arguments.contains { ["--basic", "--digest", "--ntlm"].contains($0) },
                "\(verb)"
            )
        }
    }

    /// An endpoint is not expected to carry Negotiate for a named account, since the probe never
    /// settles on it for one; if one ever did, the typed password still stays at home.
    @Test("Negotiate on a named account still sends no password")
    func negotiateNeverSendsAPassword() {
        let session = Self.session(Self.ntlm, .negotiate)
        #expect(!session.sendsCredentials)
        let arguments = WebDAVProcessArguments.mkcol(session: session, backendPath: "/x")
        #expect(arguments.contains("--negotiate") && !arguments.contains("-K"))
    }

    @Test("a scheme fits an account by whether it has a name: a password for one, a ticket without")
    func schemesFitAccounts() {
        #expect(WebDAVAuthScheme.ntlm.fits(Self.ntlm))
        #expect(WebDAVAuthScheme.basic.fits(Self.ntlm))
        #expect(!WebDAVAuthScheme.negotiate.fits(Self.ntlm))
        #expect(WebDAVAuthScheme.negotiate.fits(Self.kerberos))
        #expect(!WebDAVAuthScheme.ntlm.fits(Self.kerberos))
        #expect(WebDAVAuthScheme.allCases.filter { !$0.usesPassword } == [.negotiate])
    }

    @Test("a batch spells the scheme in every section, the first still guarded by fail")
    func batchSections() {
        let requests = ["/", "/a", "/b"].enumerated().map {
            WebDAVListingRequest(backendPath: $1, outputPath: "/scratch/\($0)")
        }
        let credentials = WebDAVConfigFile.credentials(
            username: Self.ntlm.username,
            password: Self.password
        )
        let ntlm = WebDAVProcessArguments.listings(
            session: Self.session(Self.ntlm, .ntlm),
            requests: requests,
            credentials: credentials
        )
        #expect(ntlm.arguments == ["-q", "-sS", "--fail-early", "-K", "-"])
        let ntlmSections = Self.sections(ntlm.configuration)
        #expect(ntlmSections.count == 3)
        for section in ntlmSections {
            #expect(section.contains("ntlm"))
            #expect(section.contains(#"user = "DIRNEX\\probe:pr0be:pass""#))
        }
        #expect(ntlmSections[0].contains("fail"))

        // Built with a credential line on purpose: a ticket session must not send it.
        let kerberos = WebDAVProcessArguments.listings(
            session: Self.session(Self.kerberos, .negotiate),
            requests: requests,
            credentials: credentials
        )
        for section in Self.sections(kerberos.configuration) {
            #expect(section.contains("negotiate"))
            #expect(section.contains(#"user = ":""#))
            #expect(!section.contains { $0.contains("pr0be") || $0 == "ntlm" || $0 == "basic" })
        }
    }

    @Test("every range of a segmented download carries the scheme too")
    func segmentSections() throws {
        let segments = [
            DownloadSegment(number: 0, localPath: "/scratch/0", range: 0..<10),
            DownloadSegment(number: 1, localPath: "/scratch/1", range: 10..<20)
        ]
        let file = WebDAVTaggedFile(backendPath: "/big.bin", entityTag: #""tag""#)
        let ntlm = WebDAVProcessArguments.downloadSegments(
            session: Self.session(Self.ntlm, .ntlm),
            file: file,
            segments: segments,
            credentials: WebDAVConfigFile.credentials(
                username: Self.ntlm.username,
                password: Self.password
            )
        )
        #expect(Self.sections(ntlm.configuration).allSatisfy { $0.contains("ntlm") })
        let kerberos = WebDAVProcessArguments.downloadSegments(
            session: Self.session(Self.kerberos, .negotiate),
            file: file,
            segments: segments,
            credentials: nil
        )
        #expect(Self.sections(kerberos.configuration).allSatisfy {
            $0.contains("negotiate") && $0.contains(#"user = ":""#)
        })
    }

    // MARK: - Reading real batched runs

    @Test("an NTLM level: one handshake, then every section answered on its connection")
    func ntlmLevel() throws {
        let read = WebDAVBatchWriteOut.answers(
            sections: 3,
            standardOutput: try WebDAVFixtures.text(
                "curl-exit0-ntlm-batch-level",
                extension: "stdout"
            )
        ) { _ in Data() }
        #expect(read == Array(repeating: .response(WebDAVHTTPResponse(status: 207)), count: 3))
    }

    /// The challenge's 401 is not `fail`'s: the run stopped on the refused proof, one login.
    @Test("an NTLM level with a wrong password stops on the first section's refused proof")
    func ntlmWrongPassword() throws {
        let read = WebDAVBatchWriteOut.answers(
            sections: 3,
            standardOutput: try WebDAVFixtures.text(
                "curl-exit22-ntlm-batch-login-401",
                extension: "stdout"
            )
        ) { _ in Data() }
        #expect(read == [.response(WebDAVHTTPResponse(status: 401)), .notSent, .notSent])
    }

    @Test("a Negotiate level: every section signed with the ticket and answered")
    func kerberosLevel() throws {
        let read = WebDAVBatchWriteOut.answers(
            sections: 3,
            standardOutput: try WebDAVFixtures.text(
                "curl-exit0-kerberos-batch-level",
                extension: "stdout"
            )
        ) { _ in Data() }
        #expect(read == Array(repeating: .response(WebDAVHTTPResponse(status: 207)), count: 3))
    }
}

/// The connect probe against the two stand-ins' real answers (PLAN.md §M38 Slice 6).
@Suite("WebDAVConnectProbe: NTLM and Negotiate")
struct WebDAVSignInProbeTests {
    private static let ntlm = WebDAVLocation(
        host: "127.0.0.1",
        port: 8090,
        username: #"DIRNEX\probe"#,
        usesTLS: false,
        rootPath: "/ntlm"
    )
    private static let ntlmAnonymous = WebDAVLocation(
        host: "127.0.0.1",
        port: 8090,
        username: "",
        usesTLS: false,
        rootPath: "/ntlm"
    )
    private static let kerberos = WebDAVLocation(
        host: "localhost",
        port: 8091,
        username: "",
        usesTLS: false,
        rootPath: "/negotiate"
    )
    private static let kerberosNamed = WebDAVLocation(
        host: "localhost",
        port: 8091,
        username: "probe",
        usesTLS: false,
        rootPath: "/negotiate"
    )

    private func connect(_ location: WebDAVLocation, _ server: FakeWebDAVServer) throws
        -> WebDAVConnection {
        try WebDAVConnectProbe.connect(to: location, over: server.transport)
    }

    private static func iisChallenge() throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run("curl-exit0-ntlm-iis-propfind-401")
    }

    private static func ntlmRoot() throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run("curl-exit0-ntlm-propfind-207", body: "ntlm-root-depth0-props")
    }

    private static func kerberosRoot() throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run(
            "curl-exit0-kerberos-propfind-207",
            body: "kerberos-root-depth0-props"
        )
    }

    @Test("IIS's Negotiate and NTLM: a named account signs in by NTLM, never by the ticket")
    func namedAccountTakesNTLM() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.iisChallenge() }
        server.answers[.ntlm] = { _ in try Self.ntlmRoot() }
        #expect(try connect(Self.ntlm, server) == WebDAVConnection(authentication: .ntlm))
        #expect(server.asked == [nil, .ntlm])
    }

    @Test("a refused NTLM proof is a wrong password, with no second scheme tried")
    func ntlmRefused() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.iisChallenge() }
        server.answers[.ntlm] = { _ in try WebDAVFixtures.run("curl-exit0-ntlm-wrong-password-401") }
        #expect(throws: WebDAVConnectError.credentialsRefused) { try connect(Self.ntlm, server) }
        #expect(server.asked == [nil, .ntlm])
    }

    @Test("an account with no name signs in with the Mac's ticket where Negotiate is offered")
    func noNameTakesTheTicket() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-kerberos-propfind-401") }
        server.answers[.negotiate] = { _ in try Self.kerberosRoot() }
        #expect(try connect(Self.kerberos, server) == WebDAVConnection(authentication: .negotiate))
        #expect(server.asked == [nil, .negotiate])
    }

    /// The real answer with no ticket: macOS's SPNEGO offered an NTLM token, and a server that takes
    /// Kerberos alone rejected it (`Negotiate oQcwBaADCgEC`, a SPNEGO reject).
    @Test("no ticket the server takes is said as that, not as a wrong password")
    func noTicket() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-kerberos-propfind-401") }
        server.answers[.negotiate] = { _ in
            try WebDAVFixtures.run("curl-exit0-kerberos-noticket-401")
        }
        #expect(throws: WebDAVConnectError.kerberosTicketRefused) {
            try connect(Self.kerberos, server)
        }
        #expect(server.asked == [nil, .negotiate])
    }

    /// The IIS shape again, with no name: the ticket is tried first, since NTLM has nothing to send.
    @Test("no name on IIS's Negotiate and NTLM tries the ticket, and says so when it is refused")
    func noNameOnIIS() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.iisChallenge() }
        server.answers[.negotiate] = { _ in try Self.iisChallenge() }
        #expect(throws: WebDAVConnectError.kerberosTicketRefused) {
            try connect(Self.ntlmAnonymous, server)
        }
        #expect(server.asked == [nil, .negotiate])
    }

    @Test("a named account on a server that takes only the ticket is told so, and sends nothing")
    func namedAccountOnKerberosOnly() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try WebDAVFixtures.run("curl-exit0-kerberos-propfind-401") }
        #expect(throws: WebDAVConnectError.kerberosOnly) { try connect(Self.kerberosNamed, server) }
        #expect(server.asked == [nil])
    }

    @Test(
        "public reads with NTLM behind them: Basic is answered by the NTLM challenge, and NTLM signs in"
    )
    func publicReadsThenNTLM() throws {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.ntlmRoot() }
        server.answers[.basic] = { _ in try Self.iisChallenge() }
        server.answers[.ntlm] = { _ in try Self.ntlmRoot() }
        #expect(try connect(Self.ntlm, server).authentication == .ntlm)
        #expect(server.asked == [nil, .basic, .ntlm])
    }

    @Test("public reads with only the ticket behind them: a named account is told so")
    func publicReadsThenKerberosOnly() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.kerberosRoot() }
        server.answers[.basic] = { _ in try WebDAVFixtures.run("curl-exit0-kerberos-propfind-401") }
        #expect(throws: WebDAVConnectError.kerberosOnly) { try connect(Self.kerberosNamed, server) }
        #expect(server.asked == [nil, .basic])
    }

    @Test("a 401 with no challenge at all, after Basic on public reads, is a refused password")
    func bareRefusalAfterPublicReads() {
        let server = FakeWebDAVServer()
        server.answers[nil] = { _ in try Self.ntlmRoot() }
        server.answers[.basic] = { _ in WebDAVHTTPResponse(status: 401) }
        #expect(throws: WebDAVConnectError.credentialsRefused) { try connect(Self.ntlm, server) }
    }
}
