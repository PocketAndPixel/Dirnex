import Foundation
import Testing

@testable import DirnexCore

/// The segmented download's invocation and the reader of what it printed: every section a whole,
/// guarded range request, and one answer per segment read off real runs through this builder
/// against macOS's Apache (2026-10-24).
@Suite("WebDAV segmented download: arguments and write-out")
struct WebDAVSegmentedArgumentsTests {
    private static let location = WebDAVLocation(
        host: "127.0.0.1",
        port: 8088,
        username: "probe",
        usesTLS: false,
        rootPath: "/basic"
    )
    private static let password = "pr0be:pass"
    private static let pin = "9VWU316BB0v4eXOWzMuNlgU+kWpYKiU6FCIdymE2B2A="
    /// The tag the captured runs carried, as Apache spells it.
    private static let tag = #""2800000-65e98089fe340""#
    /// The 40 MiB file every capture but the whole-file one split.
    static let large = SegmentedDownloadPlan(totalSize: 41_943_040, limits: .webdav)!
    /// The 16 MiB file the whole-file capture split.
    static let medium = SegmentedDownloadPlan(totalSize: 16_777_216, limits: .webdav)!

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
        path: String = "/big.bin",
        plan: SegmentedDownloadPlan = Self.large
    ) -> WebDAVBatchInvocation {
        WebDAVProcessArguments.downloadSegments(
            session: session,
            file: WebDAVTaggedFile(backendPath: path, entityTag: Self.tag),
            segments: plan.segments(under: URL(fileURLWithPath: "/scratch")),
            credentials: WebDAVConfigFile.credentials(username: "probe", password: Self.password)
        )
    }

    private func sections(_ invocation: WebDAVBatchInvocation) -> [[String]] {
        invocation.configuration.components(separatedBy: "next\n").map {
            $0.split(separator: "\n").map(String.init)
        }
    }

    // MARK: - The invocation

    @Test("argv starts every section at once, -q first, and carries no secret and no URL")
    func argumentsCarryNothing() {
        let arguments = invocation(session()).arguments
        #expect(arguments == [
            "-q", "-Z", "--parallel-immediate", "--parallel-max", "4", "-sS", "-K", "-"
        ])
        #expect(!arguments.joined().contains("pr0be"))
        #expect(!arguments.joined().contains("probe"))
        #expect(!arguments.joined().contains("http"))
    }

    @Test("the plan's ranges, one guarded section each, inclusive at both ends")
    func everySectionIsAGuardedRange() {
        let session = session()
        let split = sections(invocation(session))
        #expect(Self.large.segmentCount == 4)
        #expect(split.count == 4)
        let url = session.location.url(
            forBackendPath: "/big.bin",
            isCollection: false,
            host: "127.0.0.1"
        )
        let ranges = ["0-10485759", "10485760-20971519", "20971520-31457279", "31457280-41943039"]
        for (number, (section, range)) in zip(split, ranges).enumerated().map({ ($0 + 1, $1) }) {
            #expect(section.contains(#"header = "If-Match: \"2800000-65e98089fe340\"""#))
            #expect(section.contains("range = \"\(range)\""))
            #expect(section.contains("output = \"/scratch/\(number)\""))
            #expect(section.contains(
                "write-out = \"dav-seg=\(number) %{http_code} %{exitcode} %{size_download}\\n\""
            ))
            #expect(section.contains("fail"))
            #expect(section.contains("max-time = 120"))
            #expect(section.last == "url = \"\(url)\"")
            #expect(!section.contains { $0.contains("continue-at") || $0.contains("If-Range") })
        }
    }

    @Test("every section carries the credential, the scheme, the pin and -4")
    func everySectionReachesTheServerTheSameWay() {
        let pinned = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "probe",
            usesTLS: true,
            rootPath: "/home"
        )
        let split = sections(invocation(session(
            pinned,
            dial: DialedHost(host: "nas.local", restrictsToIPv4: true),
            trust: .pinned(publicKey: Self.pin),
            authentication: .digest
        )))
        for section in split {
            #expect(section.contains("digest"))
            #expect(section.contains(#"user = "probe:pr0be:pass""#))
            #expect(section.contains("insecure"))
            #expect(section.contains("pinnedpubkey = \"sha256//\(Self.pin)\""))
            #expect(section.contains("ipv4"))
            #expect(section.last?.hasPrefix("url = \"https://nas.local:5006/home/") == true)
        }
    }

    @Test("a public share sends no credential, and plain HTTP no pin")
    func aPublicShareSendsNothing() {
        let share = WebDAVLocation(host: "127.0.0.1", port: 8088, username: "", usesTLS: false)
        let split = sections(invocation(session(share, trust: .pinned(publicKey: Self.pin))))
        for section in split {
            #expect(!section.contains { $0.hasPrefix("user") || $0 == "basic" })
            #expect(!section.contains { $0.contains("pinnedpubkey") || $0 == "insecure" })
        }
    }

    @Test("an awkward name is encoded under the href rules in every section")
    func theNameIsEncoded() {
        let split = sections(invocation(session(), path: "/d/cafe\u{301} #%;+?&=[].bin"))
        for section in split {
            #expect(
                section.last == #"url = "http://127.0.0.1:8088/basic/d/cafe%CC%81%20%23%25%3B%2B%3F%26%3D%5B%5D.bin""#
            )
        }
    }

    // MARK: - Reading a run

    private func answers(
        _ fixture: String,
        plan: SegmentedDownloadPlan = Self.large
    ) throws -> [WebDAVBatchAnswer] {
        WebDAVSegmentWriteOut.answers(
            segments: plan.segments(under: URL(fileURLWithPath: "/scratch")),
            standardOutput: try WebDAVFixtures.text(fixture, extension: "stdout")
        )
    }

    private static func ranges(_ bytes: Int64...) -> [WebDAVBatchAnswer] {
        bytes.map { .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: $0)) }
    }

    @Test("a run that split, read by segment number whatever order the lines came in")
    func aSplitRunIsRead() throws {
        let four = Self.ranges(10_485_760, 10_485_760, 10_485_760, 10_485_760)
        #expect(try answers("curl-exit0-apache-segments-206") == four)
        #expect(try answers("curl-exit0-apache-segments-https-206") == four)
        #expect(try answers("curl-exit0-apache-segments-digest-206") == four)
        // The control: the HTTPS run's lines really are out of order.
        let text = try WebDAVFixtures.text(
            "curl-exit0-apache-segments-https-206",
            extension: "stdout"
        )
        #expect(text.hasPrefix("dav-seg=4 "))
    }

    @Test("a refusal under fail is each section's answer, exit 22 and all")
    func refusalsAreAnswers() throws {
        let refused = { (status: Int) in
            Array(
                repeating: WebDAVBatchAnswer.response(WebDAVHTTPResponse(status: status)),
                count: 4
            )
        }
        #expect(try answers("curl-exit22-apache-segments-stale-412") == refused(412))
        #expect(try answers("curl-exit22-apache-segments-wrong-password-401") == refused(401))
    }

    @Test("a range past the end is clipped to a short 206, and the next refused 416")
    func aShortFileIsMixed() throws {
        #expect(try answers("curl-exit22-apache-segments-past-end-416") == [
            .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: 10_485_760)),
            .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: 6_291_456)),
            .response(WebDAVHTTPResponse(status: 416)),
            .response(WebDAVHTTPResponse(status: 416))
        ])
    }

    @Test("a server that ignores Range answers every section with the whole file")
    func theWholeFileIsA200() throws {
        let whole = Array(
            repeating: WebDAVBatchAnswer.response(
                WebDAVHTTPResponse(status: 200, bytesDownloaded: 16_777_216)
            ),
            count: 4
        )
        #expect(try answers("curl-exit0-apache-segments-whole-200", plan: Self.medium) == whole)
    }

    @Test("no answer is each section's own exit code, a 206 cut by max-time included")
    func noAnswerIsTheSectionsOwnCode() throws {
        let none = { (failure: WebDAVTransportFailure) in
            Array(repeating: WebDAVBatchAnswer.noAnswer(failure), count: 4)
        }
        #expect(try answers("curl-exit7-segments-refused") == none(.couldNotConnect))
        #expect(try answers("curl-exit90-segments-wrong-pin") == none(.pinnedKeyMismatch))
        #expect(try answers("curl-exit28-apache-segments-cut") == none(.operationTimedOut))
        let text = try WebDAVFixtures.text("curl-exit28-apache-segments-cut", extension: "stdout")
        #expect(text.contains("dav-seg=1 206 28 "))
    }

    @Test("a segment with no line was never sent, and its last line wins")
    func missingAndRepeatedLines() {
        let segments = Self.large.segments(under: URL(fileURLWithPath: "/scratch"))
        let read = WebDAVSegmentWriteOut.answers(
            segments: segments,
            standardOutput: """
            dav-seg=1 000 7 0
            dav-seg=1 206 0 10485760
            dav-seg=9 206 0 1
            dav-seg=3 206 0 10485760
            dav-seg=4 nonsense
            """
        )
        #expect(read == [
            .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: 10_485_760)),
            .notSent,
            .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: 10_485_760)),
            .notSent
        ])
    }
}
