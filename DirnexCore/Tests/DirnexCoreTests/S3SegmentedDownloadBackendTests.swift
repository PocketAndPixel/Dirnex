import Foundation
import Testing

@testable import DirnexCore

/// The backend's half of a segmented download (docs/HISTORY.md ▸ After M19): the fork that decides whether one
/// happens at all, what it does with the answers, and that it leaves nothing behind whichever way
/// it ends.
@Suite("S3 segmented download: the backend")
struct S3SegmentedDownloadBackendTests {
    private static let location = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "photos",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )
    private static let mebibyte: Int64 = 1024 * 1024

    // MARK: - The backend

    @Test("a segmented download lands the object byte for byte, and cleans up after itself")
    func backendAssemblesTheObject() throws {
        let object = Data((0..<5000).map { UInt8($0 % 253) })
        let transport = FakeS3Transport()
        transport.objectBytes = object
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("holiday.mov").path
            let plan = try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1000))
            var reported: Int64 = 0
            let moved = try backend.downloadInSegments(
                Self.request(key: "holiday.mov", to: destination, on: backend),
                plan: plan,
                progress: { reported += $0 },
                isCancelled: { false }
            )
            #expect(moved == 5000)
            #expect(reported == 5000)
            #expect(transport.segmentRuns == [[1, 2, 3, 4, 5]])
            #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == object)
        }
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// A refusal is the object's own answer, so it is reported rather than retried whole — and the
    /// destination must not be left holding the pieces that did arrive.
    @Test("a refused segment fails the download and leaves no file behind")
    func refusedSegmentFails() throws {
        let transport = FakeS3Transport()
        transport.objectBytes = Data(repeating: 9, count: 5000)
        transport.segmentResponses = [
            S3Response(status: 206, bytesTransferred: 1000),
            S3Response(status: 403, body: Data(S3Fixtures.invalidAccessKey.utf8))
        ]
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("holiday.mov").path
            let plan = try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1000))
            #expect(throws: (any Error).self) {
                _ = try backend.downloadInSegments(
                    Self.request(key: "holiday.mov", to: destination, on: backend),
                    plan: plan,
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination))
        }
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// An endpoint that answers a `Range` request with the whole object has **succeeded** at
    /// something nobody asked for. That is not a failure to report — the older route produces the
    /// right file — so the backend says so and the caller fetches it in one stream.
    @Test("an endpoint that ignores ranges sends the caller back to one stream")
    func ignoredRangesAskForAWholeDownload() throws {
        let transport = FakeS3Transport()
        transport.objectBytes = Data(repeating: 3, count: 5000)
        transport.ignoresRanges = true
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let plan = try #require(SegmentedDownloadPlan(totalSize: 5000, segmentSize: 1000))
            let moved = try backend.downloadInSegments(
                Self.request(
                    key: "holiday.mov",
                    to: directory.appendingPathComponent("holiday.mov").path,
                    on: backend
                ),
                plan: plan,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == nil)
        }
        #expect(Self.everySegmentFileIsGone(transport))
    }

    /// The **default** is the code under test here, and it is the half that keeps the transport
    /// change additive: a transport that cannot split a request downloads the whole object and says
    /// which of the two it did, so the caller has nothing to assemble and nothing to guess.
    @Test("a transport with no segmented verb downloads the object whole, and says so")
    func defaultForwardsToOneStream() throws {
        let transport = SingleStreamTransport()
        let segments = [
            DownloadSegment(number: 1, localPath: "/tmp/1", range: 0..<100),
            DownloadSegment(number: 2, localPath: "/tmp/2", range: 100..<200)
        ]
        let outcome = try transport.downloadSegments(
            segments,
            of: "holiday.mov",
            to: "/tmp/whole",
            progress: { _ in },
            isCancelled: { false }
        )
        guard case let .whole(response) = outcome else {
            Issue.record("expected the whole object, got \(outcome)")
            return
        }
        #expect(response.status == 200)
        #expect(transport.downloaded == [Downloaded(key: "holiday.mov", localPath: "/tmp/whole")])
    }

    // MARK: - The fork

    /// The two conditions of the fork, each excluding a case segments cannot serve. Both are
    /// asserted through the real ``S3Backend/copyFile(at:to:expectedSize:progress:isCancelled:)``,
    /// which is where the threshold actually lives.
    @Test("a fresh download of a known, worthwhile size is split")
    func forkSplitsAWorthwhileDownload() throws {
        let transport = FakeS3Transport()
        transport.objectBytes = Data(count: Int(9 * Self.mebibyte))
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/clip.mov"),
                to: .local(destination),
                expectedSize: 9 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns == [[1, 2]])
            #expect(transport.downloads.isEmpty)
            #expect(Self.fileSize(destination) == 9 * Self.mebibyte)
        }
    }

    @Test("with no size hint nothing is split, and nothing is asked for one")
    func forkWithoutAHintTakesOneStream() throws {
        let transport = FakeS3Transport()
        transport.objectBytes = Data(count: Int(9 * Self.mebibyte))
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/clip.mov"),
                to: .local(directory.appendingPathComponent("clip.mov").path),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
            // The whole point of the hint: a download still costs no probe.
            #expect(transport.headKeys.isEmpty)
        }
    }

    @Test("an object under the threshold takes one stream however good the hint is")
    func forkLeavesSmallObjectsAlone() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/note.txt"),
                to: .local(directory.appendingPathComponent("note.txt").path),
                expectedSize: 8 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.count == 1)
        }
    }

    /// A partial on disk takes the resuming route untouched: segments are fetched into files of
    /// their own and have nothing to continue from, so the trade docs/HISTORY.md ▸ After M19 names — restarting at
    /// 6,7× beats resuming at 1× — applies only to a download that has not started.
    @Test("a partial already on disk still resumes, in one stream")
    func forkResumesAPartial() throws {
        let transport = FakeS3Transport()
        transport.headResponse = S3Response(status: 200, contentLength: 9 * Self.mebibyte)
        let backend = S3Backend(location: Self.location, transport: transport)

        try withDirectory { directory in
            let destination = directory.appendingPathComponent("clip.mov").path
            try Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: destination))
            try backend.copyFile(
                at: VFSPath(backend: backend.id, path: "/clip.mov"),
                to: .local(destination),
                expectedSize: 9 * Self.mebibyte,
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(transport.segmentRuns.isEmpty)
            #expect(transport.downloads.map(\.resume) == [true])
        }
    }

    // MARK: - Helpers

    private static func request(
        key: String,
        to localPath: String,
        on backend: S3Backend
    ) -> S3DownloadRequest {
        S3DownloadRequest(
            key: key,
            localPath: localPath,
            source: VFSPath(backend: backend.id, path: "/\(key)"),
            expectedSize: nil
        )
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return -1 }
        return size
    }

    /// Nothing is left behind — asked of the very files this download was given, and of the
    /// directory holding them, rather than by scanning a temp root shared with every other test in
    /// the process (which is a race, not an assertion).
    private static func everySegmentFileIsGone(_ transport: FakeS3Transport) -> Bool {
        transport.segmentRequests.flatMap { $0 }.allSatisfy { segment in
            let url = URL(fileURLWithPath: segment.localPath)
            return !FileManager.default.fileExists(atPath: segment.localPath)
                && !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-segtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

/// One whole-object download this double was asked for.
private struct Downloaded: Equatable {
    let key: String
    let localPath: String
}

/// A transport that implements only the single-stream download, so ``S3Transport``'s forwarding
/// default for a segmented one is what runs. It cannot be `FakeS3Transport` — that one implements
/// the segmented verb, which is exactly what has to be absent here.
private final class SingleStreamTransport: S3Transport, @unchecked Sendable {
    private(set) var downloaded: [Downloaded] = []

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        downloaded.append(Downloaded(key: key, localPath: localPath))
        return S3Response(status: 200)
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
