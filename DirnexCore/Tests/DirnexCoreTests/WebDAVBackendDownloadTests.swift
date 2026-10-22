import Foundation
import Testing

@testable import DirnexCore

/// Downloading from a WebDAV server (PLAN.md §M32 Slice 2): the resume decision, the progress
/// reconciliation, and what a refused or cut-short run turns into.
@Suite("WebDAV backend downloads")
struct WebDAVBackendDownloadTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let remote = VFSPath(backend: location.backendID, path: "/home/DSCF8566.JPG")
    private static let bytes = Data("0123456789".utf8)

    /// A Depth 0 answer reporting the remote file at `size` bytes.
    private static func statAnswer(size: Int) -> WebDAVHTTPResponse {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response xmlns:lp1="DAV:">
        <D:href>/home/DSCF8566.JPG</D:href><D:propstat><D:prop><lp1:resourcetype/>
        <lp1:getcontentlength>\(size)</lp1:getcontentlength></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        return WebDAVHTTPResponse(status: 207, body: Data(body.utf8))
    }

    private func copy(
        _ transport: FakeWebDAVTransport,
        to local: String,
        progress: (Int64) -> Void = { _ in }
    ) throws {
        try WebDAVBackend(location: Self.location, transport: transport).copyFile(
            at: Self.remote,
            to: .local(local),
            progress: progress,
            isCancelled: { false }
        )
    }

    @Test("a fresh download asks nothing first and reports every byte")
    func freshDownload() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = FakeWebDAVTransport()
        transport.fileBytes = Self.bytes
        var reported: Int64 = 0
        try copy(transport, to: scratch.path("a.jpg")) { reported += $0 }

        #expect(transport.propfinds.isEmpty)
        #expect(transport.downloads == [
            .init(path: "/home/DSCF8566.JPG", localPath: scratch.path("a.jpg"), resume: false)
        ])
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a.jpg"))) == Self.bytes)
        #expect(reported == 10)
    }

    @Test("a partial resumes when the server's copy is larger, and only the rest is reported")
    func resumesAPartial() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        try Data("012".utf8).write(to: URL(fileURLWithPath: scratch.path("a.jpg")))
        let transport = FakeWebDAVTransport { _ in Self.statAnswer(size: 10) }
        transport.fileBytes = Self.bytes
        var reported: Int64 = 0
        try copy(transport, to: scratch.path("a.jpg")) { reported += $0 }

        #expect(
            transport.propfinds == [
                .init(path: "/home/DSCF8566.JPG", depth: .zero, isCollection: false)
            ]
        )
        #expect(transport.downloads.first?.resume == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a.jpg"))) == Self.bytes)
        #expect(reported == 7)
    }

    /// Resuming onto a complete file answers 416 on the NAS, which would read as a failed copy.
    @Test("a partial as large as the server's copy is downloaded again rather than resumed")
    func completePartialStartsOver() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        try Self.bytes.write(to: URL(fileURLWithPath: scratch.path("a.jpg")))
        let transport = FakeWebDAVTransport { _ in Self.statAnswer(size: 10) }
        transport.fileBytes = Self.bytes
        try copy(transport, to: scratch.path("a.jpg"))
        #expect(transport.downloads.first?.resume == false)
    }

    @Test("the estimates streamed while it ran are topped up to curl's exact count")
    func reconcilesProgress() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = FakeWebDAVTransport()
        transport.fileBytes = Self.bytes
        transport.streamedProgress = [3, 4]
        var deltas: [Int64] = []
        try copy(transport, to: scratch.path("a.jpg")) { deltas.append($0) }
        #expect(deltas == [3, 4, 3])
    }

    @Test("a refused download is notFound, read from --fail's real exit 22")
    func refusedDownload() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = FakeWebDAVTransport()
        transport.downloadAnswer = { try WebDAVFixtures.run("curl-exit22-nas-get-404") }
        #expect(throws: VFSError.notFound(Self.remote)) {
            try copy(transport, to: scratch.path("a.jpg"))
        }
    }

    /// The finding this slice is built around: the run said 200 and stopped a sixth of the way in.
    /// Any reading that lets the status speak first reports a finished copy.
    @Test("a download the time budget cut short fails rather than counting as copied")
    func cutShortDownloadFails() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = FakeWebDAVTransport()
        transport.downloadAnswer = { try WebDAVFixtures.run("curl-exit28-nas-get-cut") }
        #expect(throws: VFSError.io(path: Self.remote, code: EIO)) {
            try copy(transport, to: scratch.path("a.jpg"))
        }
    }

    @Test("only the download direction is served until the write half")
    func otherDirectionsRefused() {
        let backend = WebDAVBackend(location: Self.location, transport: FakeWebDAVTransport())
        #expect(throws: VFSError.unsupported(.copyFile)) {
            try backend.copyFile(
                at: .local("/tmp/a.jpg"),
                to: Self.remote,
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(throws: VFSError.unsupported(.copyFile)) {
            try backend.copyFile(
                at: Self.remote,
                to: VFSPath(backend: Self.location.backendID, path: "/home/b.jpg"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test("a Stop before the transfer starts sends nothing")
    func cancelledBeforeStart() {
        let transport = FakeWebDAVTransport()
        #expect(throws: CancellationError.self) {
            try WebDAVBackend(location: Self.location, transport: transport).copyFile(
                at: Self.remote,
                to: .local("/tmp/never.jpg"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(transport.downloads.isEmpty)
    }
}
