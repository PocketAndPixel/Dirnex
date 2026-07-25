import Foundation
import Testing

@testable import DirnexCore

/// The transfer half of `FTPBackendTests`, split out to stay under SwiftLint's `type_body_length`.
/// These are the tests that exercise resume — the deliverable PLAN.md §M13 listed as unproven and
/// the probe on 2026-07-25 then proved live in both directions.
@Suite("FTPBackend transfers")
struct FTPBackendTransferTests {
    private let location = FTPLocation(
        host: "nas.local",
        port: 21,
        username: "sa",
        security: .explicit
    )

    private func backend(_ transport: FakeFTPTransport) -> FTPBackend {
        FTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(location), path: remote)
    }

    @Test("downloads a remote file and reports the bytes moved")
    func downloadsFile() throws {
        let transport = FakeFTPTransport()
        transport.transferBytes = 3_145_728
        var reported: Int64 = 0
        let destination = VFSPath.local(NSTemporaryDirectory() + "ftp-download-\(UUID().uuidString)")

        try backend(transport).copyFile(
            at: path("/pub/big.bin"),
            to: destination,
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(reported == 3_145_728)
        #expect(transport.downloads.count == 1)
        #expect(transport.downloads.first?.remote == "/pub/big.bin")
        #expect(transport.downloads.first?.resume == false) // no local partial exists
    }

    @Test("uploads a local file and reports the bytes moved")
    func uploadsFile() throws {
        let transport = FakeFTPTransport()
        transport.transferBytes = 42
        let source = try TemporaryFile(bytes: 42)
        defer { source.remove() }
        var reported: Int64 = 0

        try backend(transport).copyFile(
            at: .local(source.path),
            to: path("/pub/a.bin"),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(reported == 42)
        #expect(transport.uploads.count == 1)
        #expect(transport.uploads.first?.remote == "/pub/a.bin")
        // A small file skips the resume probe entirely — re-sending is cheaper than the round trip.
        #expect(transport.uploads.first?.resume == false)
        #expect(transport.fileSizeQueries.isEmpty)
    }

    /// The resume contract that differs from SFTP's: `curl` reports the bytes *it* moved, so the
    /// backend reports that number directly rather than subtracting a pre-existing size.
    @Test("a download resumes when a local partial is a proper prefix, reporting only the remainder")
    func downloadResumesFromLocalPartial() throws {
        let transport = FakeFTPTransport()
        let partial = try TemporaryFile(bytes: 1_048_576)
        defer { partial.remove() }
        transport.remoteFileSizes["/pub/big.bin"] = 3_145_728
        transport.transferBytes = 2_097_152 // what curl reports for the resumed run
        var reported: Int64 = 0

        try backend(transport).copyFile(
            at: path("/pub/big.bin"),
            to: .local(partial.path),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(transport.downloads.first?.resume == true)
        #expect(reported == 2_097_152)
    }

    @Test("a download does not resume when the local file is already complete")
    func downloadDoesNotResumeWhenComplete() throws {
        let transport = FakeFTPTransport()
        let complete = try TemporaryFile(bytes: 3_145_728)
        defer { complete.remove() }
        transport.remoteFileSizes["/pub/big.bin"] = 3_145_728
        transport.transferBytes = 3_145_728

        try backend(transport).copyFile(
            at: path("/pub/big.bin"),
            to: .local(complete.path),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.downloads.first?.resume == false)
    }

    @Test("a large upload resumes from a remote partial")
    func uploadResumesFromRemotePartial() throws {
        let transport = FakeFTPTransport()
        let source = try TemporaryFile(bytes: 3_145_728)
        defer { source.remove() }
        transport.remoteFileSizes["/pub/big.bin"] = 1_048_576
        transport.transferBytes = 2_097_152
        var reported: Int64 = 0

        try backend(transport).copyFile(
            at: .local(source.path),
            to: path("/pub/big.bin"),
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(transport.uploads.first?.resume == true)
        #expect(reported == 2_097_152)
        #expect(transport.fileSizeQueries == ["/pub/big.bin"])
    }

    @Test("a remote-to-remote copy is refused rather than silently routed through disk")
    func refusesRemoteToRemoteCopy() {
        let transport = FakeFTPTransport()
        #expect(throws: VFSError.unsupported(.remoteToRemoteCopy)) {
            try backend(transport).copyFile(
                at: path("/pub/a.bin"),
                to: path("/pub/b.bin"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
    }

    @Test("a cancelled copy throws before transferring")
    func honoursCancellation() {
        let transport = FakeFTPTransport()
        #expect(throws: CancellationError.self) {
            try backend(transport).copyFile(
                at: path("/pub/a.bin"),
                to: .local("/tmp/a.bin"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(transport.downloads.isEmpty)
    }

    // MARK: - Error mapping

    @Test("transport failures map onto the shared VFSError vocabulary")
    func mapsTransportErrors() {
        let cases: [(FTPTransportError, VFSError)] = [
            (.notFound, .notFound(path("/pub"))),
            (.permissionDenied, .permissionDenied(path("/pub"))),
            (.loginDenied, .permissionDenied(path("/pub"))),
            (.timedOut, .io(path: path("/pub"), code: EIO)),
            (.unreachable, .io(path: path("/pub"), code: EIO)),
            (.certificateChanged, .io(path: path("/pub"), code: EIO)),
            (.tlsNotAvailable, .io(path: path("/pub"), code: EIO)),
            (.tlsRequired, .io(path: path("/pub"), code: EIO))
        ]
        for (transportError, expected) in cases {
            let transport = FakeFTPTransport()
            transport.error = transportError
            #expect(throws: expected) {
                try backend(transport).listDirectory(at: path("/pub"))
            }
        }
    }

    @Test("everything on one host shares a volume identifier so its jobs serialize")
    func volumeIdentifierSerializesTheHost() {
        let sut = backend(FakeFTPTransport())
        #expect(sut.volumeIdentifier(for: path("/a")) == sut.volumeIdentifier(for: path("/b")))
        #expect(sut.volumeIdentifier(for: path("/a")) == "ftp://nas.local:21")
    }
}
