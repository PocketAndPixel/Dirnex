import Foundation
import Testing

@testable import DirnexCore

/// The `curl` arguments for the write half (PLAN.md §M32 Slice 4): one request per verb, in the
/// spelling that cannot replace something nobody chose to replace. The URL and header rules were
/// measured against macOS's Apache on 2026-10-23, and the fixtures named `curl-exit0-apache-…` are
/// what these exact arguments produced there.
@Suite("WebDAV write arguments")
struct WebDAVWriteArgumentsTests {
    private static let location = WebDAVLocation(
        host: "nas",
        port: 5006,
        username: "dirnex-test",
        rootPath: "/home"
    )
    private static let session = WebDAVSession(
        location: location,
        dial: DialedHost(host: "nas.local", restrictsToIPv4: true)
    )
    private static let odd = "/x/caf\u{E9} #%;+?&=[].txt"
    private static let oddURL = "https://nas.local:5006/home/x/caf%C3%A9%20%23%25%3B%2B%3F%26%3D%5B%5D.txt"

    /// Every builder, so the rules that hold for all of them are checked on all of them.
    private static var all: [[String]] {
        [
            WebDAVProcessArguments.mkcol(session: session, backendPath: "/x"),
            WebDAVProcessArguments.upload(session: session, localPath: "/tmp/a", backendPath: "/x/a"),
            WebDAVProcessArguments.putEmpty(session: session, backendPath: "/x/a"),
            WebDAVProcessArguments.move(session: session, backendPath: "/x/a", to: "/x/b"),
            WebDAVProcessArguments.copy(session: session, backendPath: "/x/a", to: "/x/b"),
            WebDAVProcessArguments.delete(session: session, backendPath: "/x/a")
        ]
    }

    private func header(_ name: String, in arguments: [String]) -> String? {
        arguments.indices.dropLast().first { arguments[$0] == "-H" && arguments[$0 + 1].hasPrefix(
            name + ":"
        ) }
        .map { arguments[$0 + 1] }
    }

    @Test("every write reads no ~/.curlrc, sends its password on stdin, and follows no redirect")
    func commonFlags() {
        for arguments in Self.all {
            #expect(arguments.first == "-q")
            #expect(arguments.indices.contains { arguments[$0] == "-K" && arguments[$0 + 1] == "-" })
            #expect(!arguments.contains("-u") && !arguments.contains("--user"))
            #expect(!arguments.contains("--location") && !arguments.contains("-L"))
            #expect(arguments.contains("-4"))
            // The refusal's body is part of the classification, so nothing writes with `--fail`.
            #expect(!arguments.contains("--fail"))
        }
    }

    @Test("MKCOL names a collection, with its slash")
    func mkcol() {
        let arguments = WebDAVProcessArguments.mkcol(session: Self.session, backendPath: "/x")
        #expect(arguments.suffix(3) == ["-X", "MKCOL", "https://nas.local:5006/home/x/"])
    }

    /// `curl -T` against a URL ending in `/` appends the local file's name (NOTES.md ▸ curl for S3).
    @Test("an upload never ends in a slash, carries curl's meter, and adds its condition")
    func upload() throws {
        let plain = WebDAVProcessArguments.upload(
            session: Self.session,
            localPath: "/tmp/payload.bin",
            backendPath: Self.odd
        )
        #expect(plain.suffix(3) == ["--upload-file", "/tmp/payload.bin", Self.oddURL])
        #expect(
            plain.contains("-S") && !plain.contains("-sS"),
            "the meter is an upload's only progress"
        )
        #expect(header("If-Match", in: plain) == nil && header("If-None-Match", in: plain) == nil)

        let guarded = WebDAVProcessArguments.upload(
            session: Self.session,
            localPath: "/tmp/payload.bin",
            backendPath: "/x/a",
            condition: .ifMatches(entityTag: #""bb8-65e8621628fc0""#)
        )
        #expect(header("If-Match", in: guarded) == #"If-Match: "bb8-65e8621628fc0""#)
    }

    @Test("an empty file states its length, carries no form content type, and only if absent")
    func putEmpty() {
        let arguments = WebDAVProcessArguments.putEmpty(
            session: Self.session,
            backendPath: "/x/new.txt",
            condition: .ifAbsent
        )
        #expect(arguments.suffix(7) == [
            "-X", "PUT", "--data-binary", "", "-H", "Content-Type:",
            "https://nas.local:5006/home/x/new.txt"
        ])
        #expect(header("If-None-Match", in: arguments) == "If-None-Match: *")
        #expect(!arguments.contains("--upload-file"), "-T /dev/null would be a chunked body")
    }

    /// The NAS answered a path-absolute `Destination` with a bare 400 (PLAN.md §M32).
    @Test("MOVE and COPY name an absolute destination on the dialed host, and never overwrite")
    func moveAndCopy() {
        for (method, arguments) in [
            (
                "MOVE",
                WebDAVProcessArguments.move(session: Self.session, backendPath: "/x/a", to: Self.odd)
            ),
            (
                "COPY",
                WebDAVProcessArguments.copy(session: Self.session, backendPath: "/x/a", to: Self.odd)
            )
        ] {
            #expect(arguments.contains(method))
            #expect(header("Destination", in: arguments) == "Destination: \(Self.oddURL)")
            #expect(header("Overwrite", in: arguments) == "Overwrite: F")
            #expect(arguments.last == "https://nas.local:5006/home/x/a")
            #expect(header("Depth", in: arguments) == nil)
        }
    }

    @Test("DELETE names the resource without a slash, whatever it is")
    func delete() {
        let arguments = WebDAVProcessArguments.delete(session: Self.session, backendPath: "/x")
        #expect(arguments.suffix(3) == ["-X", "DELETE", "https://nas.local:5006/home/x"])
    }
}
