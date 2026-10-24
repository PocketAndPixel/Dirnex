import Foundation
import Testing

@testable import DirnexCore

/// A large WebDAV download in several ranges at once: when it is tried, what guards it, and what
/// each way a run can come back turns into. The stat answers and the runs' answers are captured from
/// macOS's Apache through the shipped builders (2026-10-24).
@Suite("WebDAV backend segmented downloads")
struct WebDAVBackendSegmentedTests {
    private static let location = WebDAVLocation(
        host: "127.0.0.1",
        port: 8088,
        username: "probe",
        usesTLS: false,
        rootPath: "/basic"
    )
    private static let large = VFSPath(backend: location.backendID, path: "/big.bin")
    private static let fresh = VFSPath(backend: location.backendID, path: "/fresh.bin")
    private static let size = 41_943_040
    /// The captured file's size, each MiB its own byte, so a piece joined in the wrong place or
    /// twice changes the result.
    private static let bytes: Data = {
        var data = Data(capacity: size)
        for mebibyte in 0..<(size / 1_048_576) {
            data.append(Data(repeating: UInt8(mebibyte + 1), count: 1_048_576))
        }
        return data
    }()

    /// A transport whose Depth 0 answer for each file is its captured one.
    private func transport() throws -> FakeWebDAVTransport {
        let large = try WebDAVFixtures.multistatus("apache-propfind-large-file-207")
        let weak = try WebDAVFixtures.multistatus("apache-propfind-large-file-weak-207")
        let transport = FakeWebDAVTransport { request in
            switch (request.path, request.depth) {
            case ("/big.bin", .zero): large
            case ("/fresh.bin", .zero): weak
            default: WebDAVHTTPResponse(status: 404)
            }
        }
        transport.fileBytes = Self.bytes
        return transport
    }

    private func copy(
        _ backend: WebDAVBackend,
        _ source: VFSPath = Self.large,
        to local: String,
        hint: Int64? = Int64(Self.size),
        progress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws {
        try backend.copyFile(
            at: source,
            to: .local(local),
            hint: CopySourceHint(expectedSize: hint),
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The answers a captured run gave.
    private static func captured(_ name: String) -> ([DownloadSegment]) throws -> [WebDAVBatchAnswer] {
        { segments in
            WebDAVSegmentWriteOut.answers(
                segments: segments,
                standardOutput: try WebDAVFixtures.text(name, extension: "stdout")
            )
        }
    }

    // MARK: - When it splits

    @Test("a large file is stat'ed, split in four guarded by its tag, and joined exactly")
    func aLargeFileSplits() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        var reported: Int64 = 0
        try copy(WebDAVBackend(location: Self.location, transport: transport), to: scratch.path("a")) {
            reported += $0
        }

        #expect(transport.propfinds == [.init(path: "/big.bin", depth: .zero, isCollection: false)])
        #expect(transport.segmentRuns == [.init(
            path: "/big.bin",
            entityTag: #""2800000-65e98089fe340""#,
            ranges: [
                0..<10_485_760,
                10_485_760..<20_971_520,
                20_971_520..<31_457_280,
                31_457_280..<41_943_040
            ]
        )])
        #expect(transport.downloads.isEmpty)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a"))) == Self.bytes)
        #expect(reported == Int64(Self.size))
    }

    @Test("a small file, an unknown size and a partial on disk go in one stream, unasked")
    func smallUnknownAndPartialDoNotSplit() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("small"), hint: 8 * 1_048_576)
        try copy(backend, to: scratch.path("unknown"), hint: nil)
        try Self.bytes.prefix(100).write(to: URL(fileURLWithPath: scratch.path("partial")))
        try copy(backend, to: scratch.path("partial"))

        #expect(transport.segmentRuns.isEmpty)
        #expect(transport.downloads.map(\.resume) == [false, false, true])
        // Only the partial asks the server anything: whether there is more to resume.
        #expect(transport.propfinds.count == 1)
    }

    @Test("a weak tag sends no split, since nothing could guard it")
    func aWeakTagGoesInOneStream() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.fileBytes = Self.bytes.prefix(9_437_184)
        try copy(
            WebDAVBackend(location: Self.location, transport: transport),
            Self.fresh,
            to: scratch.path("a"),
            hint: 9_437_184
        )
        #expect(transport.propfinds.map(\.path) == ["/fresh.bin"])
        #expect(transport.segmentRuns.isEmpty)
        #expect(transport.downloads.count == 1)
    }

    @Test("a stat the server refuses is the file's answer, and nothing is downloaded")
    func aRefusedStatIsThrown() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        let gone = VFSPath(backend: Self.location.backendID, path: "/gone.bin")
        #expect(throws: VFSError.notFound(gone)) {
            try copy(
                WebDAVBackend(location: Self.location, transport: transport),
                gone,
                to: scratch.path("a")
            )
        }
        #expect(transport.segmentRuns.isEmpty)
        #expect(transport.downloads.isEmpty)
    }

    // MARK: - A transport that cannot split

    @Test("the protocol's default downloads the whole file in one stream and says so")
    func theDefaultForwards() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let fake = try transport()
        let backend = WebDAVBackend(location: Self.location, transport: UnsplittingTransport(fake))
        var reported: Int64 = 0
        try copy(backend, to: scratch.path("a")) { reported += $0 }

        #expect(fake.segmentRuns.isEmpty)
        #expect(fake.downloads.map(\.resume) == [false])
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a"))) == Self.bytes)
        #expect(reported == Int64(Self.size))
    }
}

// MARK: - When it comes back with nothing to join

extension WebDAVBackendSegmentedTests {
    @Test("a changed file falls back to one stream, and the next large file splits again")
    func aChangedFileFallsBack() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = Self.captured("curl-exit22-apache-segments-stale-412")
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("a"))
        #expect(transport.downloads.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a"))) == Self.bytes)

        transport.segmentAnswer = nil
        try copy(backend, to: scratch.path("b"))
        #expect(transport.segmentRuns.count == 2)
        #expect(transport.downloads.count == 1)
    }

    /// Built by hand rather than captured: the sections start within milliseconds of each other, so
    /// a file replaced between two of them could not be arranged on demand. It is the case that
    /// separates "changed" from "capped", since both have some ranges served.
    @Test("ranges served and then a 412 is a changed file, not a capped server")
    func aFileChangedMidRunDoesNotLatch() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = { segments in
            segments.map { segment in
                segment.number <= 2
                    ? .response(WebDAVHTTPResponse(status: 206, bytesDownloaded: segment.length))
                    : .response(WebDAVHTTPResponse(status: 412))
            }
        }
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("a"))
        transport.segmentAnswer = nil
        try copy(backend, to: scratch.path("b"))
        #expect(transport.segmentRuns.count == 2)
        #expect(transport.downloads.count == 1)
    }

    @Test("a server that ignores Range is not asked again on this connection")
    func theWholeFileLatches() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = { segments in
            segments.map { _ in
                .response(WebDAVHTTPResponse(status: 200, bytesDownloaded: Int64(Self.size)))
            }
        }
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("a"))
        try copy(backend, to: scratch.path("b"))

        #expect(transport.segmentRuns.count == 1)
        #expect(transport.downloads.count == 2)
        // The second asks nothing first either: the latch is read before the stat.
        #expect(transport.propfinds.count == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("b"))) == Self.bytes)
    }

    @Test("some ranges served and the rest refused latches, as a cap on connections would")
    func aPartlyServedRunLatches() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = Self.captured("curl-exit22-apache-segments-past-end-416")
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("a"))
        try copy(backend, to: scratch.path("b"))
        #expect(transport.segmentRuns.count == 1)
        #expect(transport.downloads.count == 2)
    }

    @Test("every range refused, or none answered, falls back without latching")
    func aWhollyFailedRunDoesNotLatch() throws {
        for capture in [
            "curl-exit22-apache-segments-wrong-password-401",
            "curl-exit7-segments-refused",
            "curl-exit28-apache-segments-cut"
        ] {
            let scratch = try WebDAVScratch()
            defer { scratch.remove() }
            let transport = try transport()
            transport.segmentAnswer = Self.captured(capture)
            let backend = WebDAVBackend(location: Self.location, transport: transport)
            try copy(backend, to: scratch.path("a"))
            transport.segmentAnswer = nil
            try copy(backend, to: scratch.path("b"))
            #expect(transport.segmentRuns.count == 2, "\(capture)")
            #expect(transport.downloads.count == 1, "\(capture)")
        }
    }

    @Test("a 206 short of its range is never joined: one stream, and the connection latched")
    func aShortPieceIsNotJoined() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = { segments in
            segments.map { segment in
                .response(WebDAVHTTPResponse(
                    status: 206,
                    bytesDownloaded: segment.number == 2 ? segment.length - 1 : segment.length
                ))
            }
        }
        let backend = WebDAVBackend(location: Self.location, transport: transport)
        try copy(backend, to: scratch.path("a"))
        try copy(backend, to: scratch.path("b"))
        #expect(transport.segmentRuns.count == 1)
        #expect(transport.downloads.count == 2)
        #expect(try Data(contentsOf: URL(fileURLWithPath: scratch.path("a"))) == Self.bytes)
    }

    @Test("bytes the abandoned split reported are not reported again by the stream")
    func aFallbackCountsEachByteOnce() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        transport.segmentAnswer = Self.captured("curl-exit22-apache-segments-past-end-416")
        transport.streamedProgress = [10_000_000, 20_000_000]
        var reported: Int64 = 0
        try copy(WebDAVBackend(location: Self.location, transport: transport), to: scratch.path("a")) {
            reported += $0
        }
        // 16 777 216 bytes of pieces landed first, then the stream moved the whole file.
        #expect(reported == Int64(Self.size))
    }

    @Test("a Stop during the split is thrown, and nothing is fetched again")
    func aStopIsNotRetried() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let transport = try transport()
        var stopped = false
        transport.duringSegments = { stopped = true }
        #expect(throws: CancellationError.self) {
            try copy(
                WebDAVBackend(location: Self.location, transport: transport),
                to: scratch.path("a"),
                isCancelled: { stopped }
            )
        }
        #expect(transport.downloads.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: scratch.path("a")))
    }
}

/// A transport with no segmented verb of its own, so ``WebDAVTransport``'s default answers it.
private struct UnsplittingTransport: WebDAVTransport {
    let base: FakeWebDAVTransport

    init(_ base: FakeWebDAVTransport) {
        self.base = base
    }

    func propfind(_ backendPath: String, depth: WebDAVDepth, isCollection: Bool) throws
        -> WebDAVHTTPResponse {
        try base.propfind(backendPath, depth: depth, isCollection: isCollection)
    }

    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer] {
        try base.propfindBatch(backendPaths, isCancelled: isCancelled)
    }

    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        try base.download(
            backendPath,
            to: localPath,
            resume: resume,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func mkcol(_ backendPath: String) throws -> WebDAVHTTPResponse {
        try base.mkcol(backendPath)
    }

    func upload(
        localPath: String,
        to backendPath: String,
        condition: S3WriteCondition,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        try base.upload(
            localPath: localPath,
            to: backendPath,
            condition: condition,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmpty(_ backendPath: String, condition: S3WriteCondition) throws -> WebDAVHTTPResponse {
        try base.putEmpty(backendPath, condition: condition)
    }

    func move(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        try base.move(backendPath, to: destinationPath)
    }

    func copy(_ backendPath: String, to destinationPath: String) throws -> WebDAVHTTPResponse {
        try base.copy(backendPath, to: destinationPath)
    }

    func delete(_ backendPath: String) throws -> WebDAVHTTPResponse {
        try base.delete(backendPath)
    }
}
