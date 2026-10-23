import Foundation
import Testing

@testable import DirnexCore

/// The batched listing's invocation and the reader of what it printed (PLAN.md §M32 Slice 5): every
/// section a whole request, the guard on the first, and one answer per section read off real runs
/// against macOS's Apache.
@Suite("WebDAV batched listing: arguments and write-out")
struct WebDAVBatchListingArgumentsTests {
    private static let location = WebDAVLocation(
        host: "127.0.0.1",
        port: 8088,
        username: "probe",
        usesTLS: false,
        rootPath: "/basic"
    )
    private static let password = "pr0be:pass"
    private static let pin = "9VWU316BB0v4eXOWzMuNlgU+kWpYKiU6FCIdymE2B2A="

    private func session(
        _ location: WebDAVLocation = Self.location,
        dial: DialedHost? = nil,
        trust: FTPTrust = .systemDefault,
        authentication: WebDAVAuthScheme? = .basic
    ) -> WebDAVSession {
        WebDAVSession(location: location, dial: dial, trust: trust, authentication: authentication)
    }

    private func invocation(
        _ session: WebDAVSession,
        paths: [String] = ["/tree", "/tree/a", "/tree/b"],
        password: String = Self.password
    ) -> WebDAVBatchInvocation {
        WebDAVProcessArguments.listings(
            session: session,
            requests: paths.enumerated().map {
                WebDAVListingRequest(backendPath: $1, outputPath: "/scratch/\($0)")
            },
            credentials: WebDAVConfigFile.credentials(username: "probe", password: password)
        )
    }

    /// The sections of a config, split where `curl` splits them.
    private func sections(_ invocation: WebDAVBatchInvocation) -> [[String]] {
        invocation.configuration.components(separatedBy: "next\n").map {
            $0.split(separator: "\n").map(String.init)
        }
    }

    // MARK: - The invocation

    @Test("argv is -q first, --fail-early and stdin, and carries no secret and no account")
    func argumentsCarryNothing() {
        let arguments = invocation(session()).arguments
        #expect(arguments == ["-q", "-sS", "--fail-early", "-K", "-"])
        #expect(!arguments.joined().contains("pr0be"))
        #expect(!arguments.joined().contains("probe"))
    }

    @Test("one section per folder, each a whole Depth 1 PROPFIND of the folder as a collection")
    func everySectionIsWhole() {
        let session = session()
        let split = sections(invocation(session))
        #expect(split.count == 3)
        for (index, (section, path)) in zip(split, ["/tree", "/tree/a", "/tree/b"]).enumerated() {
            #expect(section.contains(#"request = "PROPFIND""#))
            #expect(section.contains(#"header = "Depth: 1""#))
            #expect(section.contains(#"max-time = 120"#))
            #expect(section.contains(#"connect-timeout = 15"#))
            #expect(section.contains("output = \"/scratch/\(index)\""))
            let url = session.location.url(
                forBackendPath: path,
                isCollection: true,
                host: "127.0.0.1"
            )
            #expect(section.last == "url = \"\(url)\"")
            #expect(url.hasSuffix("/"))
            #expect(section.contains {
                $0 == "write-out = \"dav-batch=\(index) %{http_code} %{exitcode}\\n\""
            })
        }
    }

    /// The whole point of the guard: a wrong password was four refused logins in Apache's log
    /// without it, and one with it.
    @Test("only the first section stops the run on a refusal")
    func onlyTheFirstSectionFails() {
        let split = sections(invocation(session()))
        #expect(split[0].contains("fail"))
        #expect(split.dropFirst().allSatisfy { !$0.contains("fail") })
    }

    @Test("the credential and its scheme go in every section, since next resets them")
    func credentialPerSection() {
        let basic = sections(invocation(session()))
        #expect(
            basic.allSatisfy { $0.contains(#"user = "probe:pr0be:pass""#) && $0.contains("basic") }
        )

        let digest = sections(invocation(session(authentication: .digest)))
        #expect(digest.allSatisfy { $0.contains("digest") && !$0.contains("basic") })
    }

    @Test("a public share, or a request without a scheme, sends no credential at all")
    func publicShareSendsNothing() {
        let anonymous = WebDAVLocation(host: "127.0.0.1", port: 8088, username: "", usesTLS: false)
        for config in [
            invocation(session(anonymous)).configuration,
            invocation(session(authentication: nil)).configuration
        ] {
            #expect(!config.contains("user ="))
            #expect(!config.contains("basic\n") && !config.contains("digest\n"))
        }
    }

    @Test("a pin travels with insecure, per section, and only over HTTPS")
    func pinOverTLSOnly() {
        let https = WebDAVLocation(
            host: "127.0.0.1",
            port: 8443,
            username: "probe",
            rootPath: "/basic"
        )
        let pinned = sections(invocation(session(https, trust: .pinned(publicKey: Self.pin))))
        #expect(pinned.allSatisfy {
            $0.contains("insecure") && $0.contains("pinnedpubkey = \"sha256//\(Self.pin)\"")
        })

        let unpinned = invocation(session(https)).configuration
        #expect(!unpinned.contains("insecure") && !unpinned.contains("pinnedpubkey"))

        let plain = invocation(session(trust: .pinned(publicKey: Self.pin))).configuration
        #expect(!plain.contains("insecure") && !plain.contains("pinnedpubkey"))
    }

    @Test("an mDNS name is held to IPv4 in every section")
    func ipv4PerSection() {
        let dialed = DialedHost(host: "nas.local", restrictsToIPv4: true)
        let split = sections(invocation(session(dial: dialed)))
        #expect(split.allSatisfy { $0.contains("ipv4") })
        #expect(split.allSatisfy { $0.last?.contains("://nas.local:8088/") == true })
        #expect(!invocation(session()).configuration.contains("ipv4"))
    }

    /// An unescaped newline in a value makes `curl` read the rest as directives.
    @Test("a password with a quote and a newline cannot add a directive")
    func injectionGuard() {
        let hostile = "x\"\nurl = \"http://elsewhere.example/\""
        let config = invocation(session(), paths: ["/tree"], password: hostile).configuration
        let lines = config.split(separator: "\n")
        #expect(!lines.contains { $0.hasPrefix("url = \"http://elsewhere") })
        #expect(lines.filter { $0.hasPrefix("url = ") }.count == 1)
    }

    // MARK: - Reading what the run printed

    private func answers(_ name: String, sections: Int, bodies: [String?] = []) throws
        -> [WebDAVBatchAnswer] {
        let stdout = try WebDAVFixtures.text(name, extension: "stdout")
        let loaded = try bodies.map { name in
            try name.map { try WebDAVFixtures.data(
                $0,
                extension: $0.hasSuffix("404") ? "html" : "xml"
            ) }
        }
        return WebDAVBatchWriteOut.answers(sections: sections, standardOutput: stdout) { section in
            (section < loaded.count ? loaded[section] : nil) ?? Data()
        }
    }

    @Test("a level with a missing folder in it: four answers, the 404 among them, bodies by section")
    func levelWithAMissingFolder() throws {
        let bodies = [
            "apache-tree-root-207",
            "apache-tree-a-207",
            "apache-batch-missing-404",
            "apache-tree-b-207"
        ]
        let read = try answers("curl-exit0-apache-batch-level", sections: 4, bodies: bodies)
        let statuses = read.map { answer -> Int? in
            guard case let .response(response) = answer else { return nil }
            return response.status
        }
        #expect(statuses == [207, 207, 404, 207])
        for (answer, name) in zip(read, bodies) {
            guard case let .response(response) = answer else { continue }
            let expected = try WebDAVFixtures.data(
                name,
                extension: name.hasSuffix("404") ? "html" : "xml"
            )
            #expect(response.body == expected)
        }
    }

    @Test("a refused login is the first section's 401, and nothing after it was sent")
    func refusedLogin() throws {
        let read = try answers("curl-exit22-apache-batch-login-401", sections: 4)
        #expect(read.first == .response(WebDAVHTTPResponse(status: 401)))
        #expect(read.dropFirst().allSatisfy { $0 == .notSent })
    }

    @Test("a first folder that is missing stops the run on its 404")
    func missingFirstFolder() throws {
        let read = try answers("curl-exit22-apache-batch-first-404", sections: 3)
        #expect(read == [.response(WebDAVHTTPResponse(status: 404)), .notSent, .notSent])
    }

    @Test("a refused connection and a wrong pin are no answer, named by the section's exit code")
    func noAnswer() throws {
        #expect(try answers("curl-exit7-batch-refused", sections: 2)
            == [.noAnswer(.couldNotConnect), .notSent])
        #expect(try answers("curl-exit90-batch-wrong-pin", sections: 2)
            == [.noAnswer(.pinnedKeyMismatch), .notSent])
    }

    @Test("Digest answers every section, its 401s inside each")
    func digestLevel() throws {
        let read = try answers("curl-exit0-apache-batch-digest", sections: 2)
        #expect(read.allSatisfy {
            guard case let .response(response) = $0 else { return false }
            return response.status == 207
        })
    }

    /// A single run cut short by `--max-time` reported 200 with exit 28 (NOTES.md ▸ curl
    /// (WebDAV)); a section is read by the same rule.
    @Test("a section cut short keeps the status it saw and is still no answer")
    func cutShort() {
        let read = WebDAVBatchWriteOut.answers(
            sections: 2,
            standardOutput: "dav-batch=0 207 0\ndav-batch=1 207 28\n"
        ) { _ in Data() }
        #expect(read[0] == .response(WebDAVHTTPResponse(status: 207)))
        #expect(read[1] == .noAnswer(.operationTimedOut))
    }

    @Test("the last line for a section wins, and a line for no such section is ignored")
    func lastLineWins() {
        let read = WebDAVBatchWriteOut.answers(
            sections: 2,
            standardOutput: "dav-batch=1 207 0\ndav-batch=7 207 0\ngarbage\ndav-batch=0 207 0\ndav-batch=1 403 0\n"
        ) { _ in Data() }
        #expect(read == [
            .response(WebDAVHTTPResponse(status: 207)),
            .response(WebDAVHTTPResponse(status: 403))
        ])
    }
}
