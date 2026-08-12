import Foundation
import Testing

@testable import DirnexCore

/// The transfer half of the S3 backend — the resume decision, which is where the measurements
/// live, and the capability set the panel grays operations out from.
///
/// Split from `S3BackendTests` by concept rather than to shave lines: the listing suite is about
/// what the *server* said, and this one is about what is already on the local disk.
@Suite("S3 backend transfers")
struct S3BackendTransferTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(location: location, transport: transport)
    }

    @Test("a fresh download never pays for a size probe")
    func downloadsWithoutResuming() throws {
        let transport = FakeS3Transport()
        transport.downloadResponse = S3Response(status: 200, bytesTransferred: 257_098)
        let local = "\(NSTemporaryDirectory())s3-test-\(UUID().uuidString)"
        var reported: Int64 = 0

        try backend(transport).copyFile(
            at: VFSPath(backend: .s3(location), path: "/CHANGELOG"),
            to: .local(local),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(reported == 257_098)
        #expect(transport.headKeys.isEmpty)
        #expect(transport.downloads == [
            .init(key: "CHANGELOG", localPath: local, resume: false)
        ])
    }

    @Test("a local partial that is a proper prefix resumes")
    func resumesFromAPartial() throws {
        let partial = try TemporaryFile(bytes: 100_000)
        defer { partial.remove() }
        let transport = FakeS3Transport()
        transport.headResponse = S3Response(status: 200, contentLength: 257_098)
        transport.downloadResponse = S3Response(status: 206, bytesTransferred: 157_098)
        var reported: Int64 = 0

        try backend(transport).copyFile(
            at: VFSPath(backend: .s3(location), path: "/CHANGELOG"),
            to: .local(partial.path),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(transport.headKeys == ["CHANGELOG"])
        #expect(transport.downloads.first?.resume == true)
        // The delta, not the whole object — `curl` reports what it actually moved.
        #expect(reported == 157_098)
    }

    /// Resuming onto an already-complete file answers 416, which this backend would report as a
    /// failed copy of a file that is in fact already there. The size probe is what avoids it.
    @Test("a complete local file is re-fetched rather than resumed onto")
    func doesNotResumeOntoACompleteFile() throws {
        let complete = try TemporaryFile(bytes: 257_098)
        defer { complete.remove() }
        let transport = FakeS3Transport()
        transport.headResponse = S3Response(status: 200, contentLength: 257_098)
        transport.downloadResponse = S3Response(status: 200, bytesTransferred: 257_098)

        try backend(transport).copyFile(
            at: VFSPath(backend: .s3(location), path: "/CHANGELOG"),
            to: .local(complete.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.downloads.first?.resume == false)
    }

    @Test("an upload is refused until the write half lands")
    func refusesAnUpload() {
        let transport = FakeS3Transport()
        #expect(throws: VFSError.unsupported(.copyFile)) {
            try backend(transport).copyFile(
                at: .local("/tmp/a.txt"),
                to: VFSPath(backend: .s3(location), path: "/a.txt"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.downloads.isEmpty)
    }

    // MARK: - Capabilities

    @Test("read only, and no watching ever")
    func capabilities() {
        let capabilities = backend(FakeS3Transport()).capabilities
        #expect(capabilities.contains(.read))
        #expect(!capabilities.contains(.write))
        #expect(!capabilities.contains(.watch))
        #expect(capabilities.deleteStrategy == .unsupported)
    }

    @Test("jobs on one bucket share a volume")
    func volumeIdentifier() {
        let backend = backend(FakeS3Transport())
        let first = backend.volumeIdentifier(for: VFSPath(backend: .s3(location), path: "/a"))
        let second = backend.volumeIdentifier(for: VFSPath(backend: .s3(location), path: "/b/c"))
        #expect(first == second)
        #expect(first == "s3://s3.us-east-1.amazonaws.com:443/1000genomes")
    }
}
