import Foundation
import Testing

@testable import DirnexCore

@Suite("S3 part slicing")
struct S3PartSliceTests {
    /// A temp directory that cleans itself up, holding a file of known bytes.
    private func withFixture(
        bytes: [UInt8],
        _ body: (String, String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-slice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        try Data(bytes).write(to: source)
        try body(source.path, directory.appendingPathComponent("slice.bin").path)
    }

    @Test("a slice holds exactly the bytes of its range")
    func sliceIsExact() throws {
        let bytes = (0..<200).map { UInt8($0 % 256) }
        try withFixture(bytes: bytes) { source, slice in
            let written = try S3PartSlice.write(from: source, range: 50..<130, to: slice)
            #expect(written == 80)
            let data = try Data(contentsOf: URL(fileURLWithPath: slice))
            #expect(Array(data) == Array(bytes[50..<130]))
        }
    }

    @Test("a slice larger than the copy buffer is still exact")
    func sliceSpansManyBuffers() throws {
        // Three buffers and a remainder, so the loop's own boundary is crossed rather than assumed.
        let length = S3PartSlice.bufferSize * 3 + 17
        let bytes = (0..<length).map { UInt8($0 % 251) }
        try withFixture(bytes: bytes) { source, slice in
            let written = try S3PartSlice.write(from: source, range: 0..<Int64(length), to: slice)
            #expect(written == Int64(length))
            let data = try Data(contentsOf: URL(fileURLWithPath: slice))
            #expect(Array(data) == bytes)
        }
    }

    @Test("the final short part is exact too")
    func finalPartIsShort() throws {
        let bytes = (0..<100).map { UInt8($0) }
        try withFixture(bytes: bytes) { source, slice in
            let written = try S3PartSlice.write(from: source, range: 90..<100, to: slice)
            #expect(written == 10)
            let data = try Data(contentsOf: URL(fileURLWithPath: slice))
            #expect(Array(data) == Array(bytes[90..<100]))
        }
    }

    @Test("a source that shrank under the upload is a failure, not a short part")
    func shrunkSourceIsRefused() throws {
        // S3 would assemble a short part into the object and call it a success, so this has to fail
        // here — the file being uploaded is no longer the file that was planned.
        let bytes = (0..<100).map { UInt8($0) }
        try withFixture(bytes: bytes) { source, slice in
            #expect(throws: S3PartSliceError.self) {
                try S3PartSlice.write(from: source, range: 60..<200, to: slice)
            }
        }
    }

    @Test("a source that is not there is a failure")
    func missingSourceIsRefused() {
        #expect(throws: S3PartSliceError.self) {
            try S3PartSlice.write(
                from: "/nonexistent/dirnex/source.bin",
                range: 0..<10,
                to: FileManager.default.temporaryDirectory.appendingPathComponent("x").path
            )
        }
    }
}

@Suite("S3 multipart upload")
struct S3MultipartUploadTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func destination(_ path: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: path)
    }

    /// A local file of `size` bytes to upload, removed afterwards.
    private func withLocalFile(size: Int, _ body: (String) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-upload-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<size).map { UInt8($0 % 256) }).write(to: url)
        try body(url.path)
    }

    /// The request the orchestration tests drive. The part size is *stated* rather than derived so a
    /// whole multi-part upload can be exercised over a few kilobytes: the orchestration is
    /// size-agnostic, and the policy that picks a real part size is pinned separately in
    /// `S3MultipartPlanTests`.
    private func smallRequest(localPath: String, totalSize: Int64) throws -> S3MultipartRequest {
        S3MultipartRequest(
            localPath: localPath,
            key: "big.bin",
            destination: destination("/big.bin"),
            plan: try #require(S3MultipartPlan(totalSize: totalSize, partSize: 400))
        )
    }

    // MARK: - The happy path

    @Test("an upload opens, sends every part, and completes — in that order")
    func uploadSequence() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            let moved = try backend.uploadInParts(
                try smallRequest(localPath: localPath, totalSize: 1000),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(moved == 1000)
        }

        #expect(transport.writes.count == 5) // create + 3 parts + complete
        guard case let .createMultipart(key) = transport.writes.first else {
            Issue.record("first write was not the create: \(transport.writes)")
            return
        }
        #expect(key == "big.bin")
        guard case let .completeMultipart(_, uploadID, parts) = transport.writes.last else {
            Issue.record("last write was not the completion: \(transport.writes)")
            return
        }
        #expect(uploadID == S3Fixtures.initiateUploadID)
        #expect(parts.map(\.number) == [1, 2, 3])
        #expect(parts.map(\.etag) == ["\"etag-part-1\"", "\"etag-part-2\"", "\"etag-part-3\""])
    }

    @Test("each part carries the upload id the server handed back")
    func partsQuoteTheUploadID() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            _ = try backend.uploadInParts(
                try smallRequest(localPath: localPath, totalSize: 1000),
                progress: { _ in },
                isCancelled: { false }
            )
        }

        let uploads = transport.writes.compactMap { write -> FakeS3Transport.PartUpload? in
            guard case let .uploadPart(part) = write else { return nil }
            return part
        }
        #expect(uploads.map(\.partNumber) == [1, 2, 3])
        #expect(uploads.allSatisfy { $0.uploadID == S3Fixtures.initiateUploadID })
    }

    @Test("the slices sent are the plan's own ranges")
    func slicesMatchThePlan() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)

        try withLocalFile(size: 1000) { localPath in
            _ = try backend.uploadInParts(
                try smallRequest(localPath: localPath, totalSize: 1000),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        // 400 + 400 + 200: the last part is the remainder, and every slice really existed on disk
        // at the moment its part was uploaded.
        #expect(transport.sliceSizes == [400, 400, 200])
    }

    @Test("progress reports one delta per part, summing to the file")
    func progressIsPerPartDelta() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)
        var deltas: [Int64] = []

        try withLocalFile(size: 1000) { localPath in
            _ = try backend.uploadInParts(
                try smallRequest(localPath: localPath, totalSize: 1000),
                progress: { deltas.append($0) },
                isCancelled: { false }
            )
        }
        // Deltas, not a running total: `CopyEngine` adds them up, so cumulative values here would
        // count every byte of a large file several times over.
        #expect(deltas == [400, 400, 200])
        #expect(deltas.reduce(0, +) == 1000)
    }

    // MARK: - Routing

    @Test("a small file takes the single PUT and never opens a multipart upload")
    func smallFileTakesSinglePut() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)
        var deltas: [Int64] = []

        try withLocalFile(size: 4096) { localPath in
            transport.writeResponse = S3Response(status: 200, bytesTransferred: 4096)
            try backend.copyFile(
                at: VFSPath(backend: .local, path: localPath),
                to: destination("/small.bin"),
                progress: { deltas.append($0) },
                isCancelled: { false }
            )
        }
        #expect(transport.writes.count == 1)
        guard case .upload = transport.writes.first else {
            Issue.record("a small file did not take the single PUT: \(transport.writes)")
            return
        }
        #expect(deltas == [4096])
    }

    @Test("a file over the threshold routes to multipart through copyFile")
    func largeFileRoutesToMultipart() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: location, transport: transport)

        // Sparse: `truncate` sets the length without writing 65 MiB, so this costs no real disk and
        // the read still yields the bytes the plan expects.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3-large-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try #require(FileHandle(forWritingAtPath: url.path))
        let size = S3MultipartLimits.multipartThreshold + 1
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()

        var total: Int64 = 0
        try backend.copyFile(
            at: VFSPath(backend: .local, path: url.path),
            to: destination("/large.bin"),
            progress: { total += $0 },
            isCancelled: { false }
        )

        #expect(total == size)
        guard case .createMultipart = transport.writes.first else {
            Issue.record("a large file did not go multipart: \(transport.writes.count) writes")
            return
        }
        #expect(completed(transport))
    }

    // MARK: - Helpers

    private func aborted(_ transport: FakeS3Transport) -> Bool {
        transport.writes.contains {
            if case .abortMultipart = $0 { return true }
            return false
        }
    }

    private func completed(_ transport: FakeS3Transport) -> Bool {
        transport.writes.contains {
            if case .completeMultipart = $0 { return true }
            return false
        }
    }
}
