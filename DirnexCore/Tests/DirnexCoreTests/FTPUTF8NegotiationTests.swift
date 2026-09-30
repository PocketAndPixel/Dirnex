import Foundation
import Testing

@testable import DirnexCore

/// That every `curl` invocation asks the server to speak UTF-8 for file names.
///
/// Its own file rather than another section of ``FTPProcessArgumentsTests`` because it is its own
/// subject — that suite is about *which flags* each verb carries and above all that no credential
/// reaches `argv`; this is about the encoding names travel in. (It also sits at SwiftLint's
/// `type_body_length`, and the house rule is to split by concept rather than shave lines.)
@Suite("FTP UTF-8 negotiation")
struct FTPUTF8NegotiationTests {
    private let plain = FTPLocation(host: "nas.local", username: "sa", security: .plain)

    private func session(_ location: FTPLocation) -> FTPSession {
        FTPSession(location: location, trust: .systemDefault, tls: .negotiate)
    }

    /// Every invocation asks the server to speak UTF-8, because every one of them either reads a
    /// name or sends one.
    ///
    /// Reported 2026-09-09 with three screenshots: a NAS holding `DSC_0697-Панорама.jpg`, an SFTP
    /// pane showing it correctly, and an FTP pane showing `DSC_0697-.jpg`. Measured against that
    /// server, the code page corrupts names in both directions — `LIST` returns one `0x7F` per
    /// unmappable character (valid UTF-8, so it parses and simply does not draw), and an *upload*
    /// is stored as `ÐŸÐ°Ð½Ð¾Ñ€Ð°Ð¼Ð°`, which is permanent. See ``FTPProcessArguments/utf8Negotiation``.
    @Test("every builder asks the server for UTF-8 names")
    func everyInvocationNegotiatesUTF8() {
        let all: [(String, [String])] = [
            ("list", FTPProcessArguments.list(session: session(plain), remotePath: "/pub")),
            ("download", FTPProcessArguments.download(
                session: session(plain), remotePath: "/a.bin", localPath: "/tmp/a", resume: false
            )),
            ("upload", FTPProcessArguments.upload(
                session: session(plain), localPath: "/tmp/a", remotePath: "/a.bin", resume: false
            )),
            ("createFile", FTPProcessArguments.createFile(
                session: session(plain), localPath: "/tmp/e", remotePath: "/new.txt", append: true
            )),
            ("head", FTPProcessArguments.head(session: session(plain), remotePath: "/a.bin")),
            ("quote", FTPProcessArguments.quote(
                session: session(plain), commands: ["RNFR /a", "RNTO /b"]
            ))
        ]
        for (name, arguments) in all {
            let negotiates = zip(arguments, arguments.dropFirst()).contains {
                $0 == "--quote" && $1 == FTPProcessArguments.utf8Negotiation
            }
            #expect(negotiates, "\(name) does not negotiate UTF-8")
        }
    }

    /// The negotiation is **allowed to fail**, and that is what keeps a server which has never
    /// heard of `OPTS` working at all.
    ///
    /// Measured against a server that refuses it: unprefixed, `curl` exits **21** printing
    /// `QUOT command failed with 501` — and that reply code is exactly what
    /// ``FTPTransportError/classify(exitCode:stderr:)`` reads out of stderr, so every operation
    /// would fail *and* be explained by the wrong number. Prefixed, the same run exits 0 with
    /// stderr empty.
    @Test("it is allowed to fail, and is sent before the transfer rather than after it")
    func theNegotiationIsTolerated() {
        #expect(FTPProcessArguments.utf8Negotiation.hasPrefix("*"))
        // `-` is curl's *post*-transfer marker. This one has to run first: `RNFR`/`RNTO`, `MKD` and
        // `DELE` all carry names that must be spoken once the encoding is settled.
        #expect(!FTPProcessArguments.utf8Negotiation.hasPrefix("-"))
    }

    /// A batch reads one option set per transfer, so a section that omits the negotiation gets the
    /// server's code page for a whole level of the tree.
    @Test("every section of a batched listing and a segmented download carries it too")
    func everySectionNegotiatesUTF8() {
        let listing = FTPProcessArguments.listDirectories(
            session: session(plain),
            requests: [
                FTPListingRequest(remotePath: "/a", outputPath: "/tmp/a.txt"),
                FTPListingRequest(remotePath: "/b", outputPath: "/tmp/b.txt")
            ],
            credentials: "user = \"sa:pw\"\n"
        )
        let listingSections = listing.configuration.components(separatedBy: "next\n")
        #expect(listingSections.count == 2)
        for section in listingSections {
            #expect(section.contains(FTPProcessArguments.utf8Negotiation))
        }

        let download = FTPProcessArguments.downloadSegments(
            session: session(plain),
            remotePath: "/big.bin",
            segments: [
                DownloadSegment(number: 1, localPath: "/tmp/0", range: 0..<10),
                DownloadSegment(number: 2, localPath: "/tmp/1", range: 10..<20)
            ],
            credentials: "user = \"sa:pw\"\n"
        )
        let downloadSections = download.configuration.components(separatedBy: "next\n")
        #expect(downloadSections.count == 2)
        for section in downloadSections {
            #expect(section.contains(FTPProcessArguments.utf8Negotiation))
        }
    }
}
