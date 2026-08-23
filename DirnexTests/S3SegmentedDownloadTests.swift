import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The three app-side halves of a segmented download: how its progress is read, how long the runner
/// is willing to wait for one, and — the one that fails with no symptom at all — whether the pane's
/// routing backend passes the size hint along (docs/HISTORY.md ▸ After M19).
///
/// All three are invisible in a green run. A progress source that reads nothing leaves the bar still
/// for the whole transfer; a backstop derived from the wrong place kills a healthy download part-way
/// through; and a hint that stops at the composite leaves every download on the single-stream
/// default, with the same rows, the same bytes, and nothing anywhere to say so.
@Suite("S3 segmented download: progress, the wait, and the hint")
struct S3SegmentedDownloadTests {
    private static let bucket = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "photos",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - Progress

    /// A segmented download is writing several files on this machine, so their combined size is the
    /// byte count — exact and continuous, where the run's own write-out lines could only ever step
    /// a whole segment at a time.
    @Test("the segment files' combined size is what is reported, forward only")
    func segmentFilesAreTheObservable() throws {
        try withDirectory { directory in
            let paths = (1...3).map { directory.appendingPathComponent("\($0)").path }
            let watch = TransferProgressWatch(.destinationFiles(paths: paths, totalBytes: 300))
            var deltas: [Int64] = []

            watch.report(to: { deltas.append($0) })
            #expect(deltas.isEmpty) // nothing has landed yet

            try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: paths[1]))
            watch.report(to: { deltas.append($0) })
            #expect(deltas == [100])

            try Data(repeating: 1, count: 100).write(to: URL(fileURLWithPath: paths[0]))
            try Data(repeating: 1, count: 60).write(to: URL(fileURLWithPath: paths[2]))
            watch.report(to: { deltas.append($0) })
            // Deltas, never a running total — what the operation queue adds up.
            #expect(deltas == [100, 160])
        }
    }

    /// The narrowness control: a turn with nothing new to say says nothing rather than repeating
    /// itself, which is what keeps a poll loop from inflating the count.
    @Test("a quiet turn reports nothing")
    func quietTurnsReportNothing() throws {
        try withDirectory { directory in
            let path = directory.appendingPathComponent("1").path
            try Data(repeating: 1, count: 40).write(to: URL(fileURLWithPath: path))
            let watch = TransferProgressWatch(.destinationFiles(paths: [path], totalBytes: 40))
            var deltas: [Int64] = []
            watch.report(to: { deltas.append($0) })
            watch.report(to: { deltas.append($0) })
            #expect(deltas == [40])
        }
    }

    /// The cap is not tidiness. An endpoint that answers a `Range` request with the whole object
    /// writes every section a full copy, and the queue's tally only ever *adds* — so without it one
    /// file would report several times its own size into a job total that never comes back down.
    /// The backend notices that answer and re-fetches in one stream; this is what keeps the report
    /// honest in the meantime.
    @Test("nothing is reported past the object's own size")
    func theTotalIsACap() throws {
        try withDirectory { directory in
            let paths = (1...2).map { directory.appendingPathComponent("\($0)").path }
            for path in paths {
                try Data(repeating: 1, count: 500).write(to: URL(fileURLWithPath: path))
            }
            let watch = TransferProgressWatch(.destinationFiles(paths: paths, totalBytes: 500))
            var reported: Int64 = 0
            watch.report(to: { reported += $0 })
            #expect(reported == 500)
        }
    }

    // MARK: - The wait

    /// A parallel run puts every per-transfer option in its **config sections**, so `argv` carries
    /// no `--max-time` at all. Read only from the arguments, the backstop would fall back to the
    /// metadata timeout and terminate a perfectly healthy download part-way through.
    @Test("the backstop reads the run's time budget out of the configuration")
    func budgetComesFromTheConfiguration() {
        let invocation = S3ProcessArguments.downloadSegments(
            session: S3Session(location: Self.bucket, connectTimeout: 15, maxTime: 3600),
            key: "holiday.mov",
            segments: [S3DownloadSegment(number: 1, localPath: "/tmp/1", range: 0..<100)],
            credentials: "user = \"id:secret\"\n"
        )
        #expect(!invocation.arguments.contains("--max-time"))
        #expect(S3CurlRunner.curlMaxTime(inConfiguration: invocation.configuration) == 3600)
    }

    // MARK: - The hint reaching the backend that moves the bytes

    /// The pane holds a `CompositeBackend`, so this forward is what decides whether the feature runs
    /// at all — and its absence produces the same file, the same rows and no error. What the test
    /// separates is *routed* from *answered*: the hint has to arrive at the S3 backend, which is the
    /// only place a segmented run can be seen.
    @Test("the composite passes the caller's size hint to the backend that moves the bytes")
    func compositeForwardsTheHint() throws {
        let transport = RecordingS3Transport(object: Data(count: Int(9 * Self.mebibyte)))
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(s3: S3Backend(location: Self.bucket, transport: transport))

        try withDirectory { directory in
            try composite.copyFile(
                at: VFSPath(backend: .s3(Self.bucket), path: "/clip.mov"),
                to: .local(directory.appendingPathComponent("clip.mov").path),
                expectedSize: 9 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.segmentRuns == [[1, 2]])
        #expect(transport.wholeDownloads == 0)
    }

    /// The narrowness control, and the half that keeps the forward from becoming "always split": a
    /// caller with nothing to say still gets exactly the download it used to.
    @Test("a copy made without a hint still takes one stream")
    func compositeWithoutAHintIsUnchanged() throws {
        let transport = RecordingS3Transport(object: Data(count: Int(9 * Self.mebibyte)))
        let composite = CompositeBackend(local: LocalBackend())
        composite.register(s3: S3Backend(location: Self.bucket, transport: transport))

        try withDirectory { directory in
            try composite.copyFile(
                at: VFSPath(backend: .s3(Self.bucket), path: "/clip.mov"),
                to: .local(directory.appendingPathComponent("clip.mov").path),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.segmentRuns.isEmpty)
        #expect(transport.wholeDownloads == 1)
    }

    /// And the second narrowness control: a copy that never leaves this disk is untouched by any of
    /// it, hint or no hint.
    @Test("a local copy still copies, hint and all")
    func localCopyIsUntouched() throws {
        let composite = CompositeBackend(local: LocalBackend())
        try withDirectory { directory in
            let source = directory.appendingPathComponent("a.txt")
            let destination = directory.appendingPathComponent("b.txt")
            try Data(repeating: 7, count: 2048).write(to: source)
            try composite.copyFile(
                at: .local(source.path),
                to: .local(destination.path),
                expectedSize: 2048,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: destination) == Data(repeating: 7, count: 2048))
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-segapp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

/// An `S3Transport` that answers from memory and writes down which of the two download shapes it
/// was asked for. The app target has no fake of its own — `DirnexCore`'s lives in that package's
/// tests — and what is under test here is the *app's* routing, so the double belongs here.
private final class RecordingS3Transport: S3Transport, @unchecked Sendable {
    private let object: Data
    private(set) var segmentRuns: [[Int]] = []
    private(set) var wholeDownloads = 0

    init(object: Data) {
        self.object = object
    }

    func downloadSegments(
        _ segments: [S3DownloadSegment],
        of key: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3SegmentedDownload {
        segmentRuns.append(segments.map(\.number))
        return .segments(segments.map { segment in
            let slice = object.subdata(
                in: Int(segment.range.lowerBound)..<min(object.count, Int(segment.range.upperBound))
            )
            try? slice.write(to: URL(fileURLWithPath: segment.localPath))
            progress(Int64(slice.count))
            return S3Response(status: 206, bytesTransferred: Int64(slice.count))
        })
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        wholeDownloads += 1
        try? object.write(to: URL(fileURLWithPath: localPath))
        return S3Response(status: 200, bytesTransferred: Int64(object.count))
    }

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func head(key: String) throws -> S3Response { S3Response(status: 200) }

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func putEmptyObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        S3Response(status: 200)
    }

    func deleteObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func deleteObjects(keys: [String]) throws -> S3Response { S3Response(status: 200) }

    func createMultipartUpload(key: String) throws -> S3Response { S3Response(status: 200) }

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        S3Response(status: 200)
    }
}
