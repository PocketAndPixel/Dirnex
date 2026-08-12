import Foundation
import Testing

@testable import DirnexCore

/// The write half against the fake transport (PLAN.md §M21).
///
/// What these pin is mostly *which requests were made, and in what order* — because that is where
/// the S3-shaped mistakes live. A rename that deletes before it copies loses the file; a folder
/// delete that reads only the status reports files as gone while they are still there; a prefix
/// move that does not answer `EXDEV` blocks the main thread on N round trips with no cancel.
/// None of those is visible in a return value.
@Suite("S3 backend writes")
struct S3BackendWriteTests {
    private let location = S3Location(
        host: "s3.us-east-1.amazonaws.com",
        bucket: "1000genomes",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(location: location, transport: transport)
    }

    private func path(_ value: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: value)
    }

    private func localPath(_ value: String) -> VFSPath {
        VFSPath(backend: .local, path: value)
    }

    // MARK: - Capabilities

    @Test("the bucket advertises write, and never clone or watch")
    func capabilities() {
        let capabilities = backend(FakeS3Transport()).capabilities
        #expect(capabilities.contains(.read))
        #expect(capabilities.contains(.write))
        // A server-side copy really moves the bytes — S3 pays, not this machine — so it is not the
        // instant same-filesystem primitive `.clone` promises `CopyEngine`.
        #expect(!capabilities.contains(.clone))
        // Permanent: S3 has no change notification.
        #expect(!capabilities.contains(.watch))
    }

    // MARK: - Creating

    @Test("a new folder is one zero-byte marker at the prefix, trailing slash included")
    func createDirectoryWritesTheMarker() throws {
        let transport = FakeS3Transport()
        try backend(transport).createDirectory(at: path("/docs"))
        #expect(transport.writes == [.putEmpty("docs/")])
    }

    @Test("a folder marker is written without asking whether the folder is there")
    func createDirectoryDoesNotProbeFirst() throws {
        let transport = FakeS3Transport()
        try backend(transport).createDirectory(at: path("/docs"))
        // Writing the same zero bytes twice leaves one object, so the extra listing would bill a
        // request to prevent nothing.
        #expect(transport.listRequests.isEmpty)
    }

    @Test("the bucket root cannot be created over")
    func createDirectoryRefusesTheRoot() {
        let transport = FakeS3Transport()
        #expect(throws: VFSError.self) {
            try backend(transport).createDirectory(at: path("/"))
        }
        #expect(transport.writes.isEmpty)
    }

    @Test("a new file checks first, because an empty PUT over a real object destroys it")
    func createFileRefusesAnExistingKey() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statFile)]
        #expect(throws: VFSError.self) {
            try backend(transport).createFile(at: path("/CHANGELOG"))
        }
        // The asymmetry with `createDirectory` is the point: nothing was written.
        #expect(transport.writes.isEmpty)
    }

    @Test("a new file at a free key is one zero-byte PUT")
    func createFileWritesAnEmptyObject() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statMissing)]
        try backend(transport).createFile(at: path("/notes.txt"))
        #expect(transport.writes == [.putEmpty("notes.txt")])
    }

    // MARK: - Renaming

    @Test("renaming one object copies server-side, then deletes the source — in that order")
    func renameCopiesThenDeletes() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statFile)]
        try backend(transport).moveItem(at: path("/CHANGELOG"), to: path("/CHANGELOG.old"))

        // The order is the whole safety property: if the delete fails the user has the file twice,
        // which is visible and fixable. The other order loses it.
        #expect(transport.writes == [
            .copy(.init(sourceKey: "CHANGELOG", destinationKey: "CHANGELOG.old")),
            .delete("CHANGELOG")
        ])
    }

    @Test("renaming a folder answers EXDEV so the engine runs it as a queued recursive move")
    func renamingAPrefixDefersToTheEngine() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statDocsFolder)]

        // `CopyEngine.perform` catches exactly this and falls back to a recursive copy-then-delete
        // with progress, cancellation and a per-item failure report.
        #expect {
            try backend(transport).moveItem(at: path("/docs"), to: path("/archive"))
        } throws: { error in
            guard case let VFSError.io(_, code) = error else { return false }
            return code == EXDEV
        }
        // And it refused *before* touching anything.
        #expect(transport.writes.isEmpty)
    }

    @Test("a move onto another backend answers EXDEV too — an upload is not a rename")
    func movingOffTheBucketDefersToTheEngine() {
        let transport = FakeS3Transport()
        #expect {
            try backend(transport).moveItem(at: path("/CHANGELOG"), to: localPath("/tmp/x"))
        } throws: { error in
            guard case let VFSError.io(_, code) = error else { return false }
            return code == EXDEV
        }
        #expect(transport.listRequests.isEmpty)
    }

    // MARK: - Removing

    @Test("deleting one object is one DELETE, with no enumeration")
    func removeFileIsOneRequest() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statFile)]
        try backend(transport).removeItem(at: path("/CHANGELOG"))
        #expect(transport.writes == [.delete("CHANGELOG")])
    }

    @Test("deleting a folder sweeps every key under it, its own marker included, in one batch")
    func removeFolderBatchesEveryKey() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statDocsFolder), .ok(S3Fixtures.recursivePage)]
        transport.deleteBatchResponses = [.ok(S3Fixtures.deleteQuiet)]
        try backend(transport).removeItem(at: path("/docs"))

        #expect(transport.writes == [
            .deleteBatch(["docs/", "docs/a.txt", "docs/sub/b.txt"])
        ])
    }

    @Test("the enumeration drops the delimiter, or it would only see the top level")
    func recursiveEnumerationAsksForEveryDepth() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statDocsFolder), .ok(S3Fixtures.recursivePage)]
        transport.deleteBatchResponses = [.ok(S3Fixtures.deleteQuiet)]
        try backend(transport).removeItem(at: path("/docs"))

        // The stat comes first (`prefix=docs`, delimited); the sweep is the second request and must
        // carry no delimiter, or `docs/sub/b.txt` is grouped into a CommonPrefix and never deleted.
        let sweep = try #require(transport.listRequests.last)
        #expect(sweep.prefix == "docs/")
        #expect(sweep.delimiter == nil)
    }

    @Test("a 200 carrying a per-key refusal is a failure, named on that key's own path")
    func partialBatchFailureIsRaised() throws {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statDocsFolder), .ok(S3Fixtures.recursivePage)]
        // The status says success. The body does not — and a reader that trusted the status would
        // report a folder as deleted with files still in it.
        transport.deleteBatchResponses = [.ok(S3Fixtures.deletePartialFailure)]

        #expect {
            try backend(transport).removeItem(at: path("/docs"))
        } throws: { error in
            guard case let VFSError.permissionDenied(target) = error else { return false }
            // Named on the key that was refused, not on the folder — pointing the user at the
            // folder would send them to check permissions on something that is fine.
            return target == path("/docs/sub/b.txt")
        }
    }

    @Test("the bucket root cannot be deleted")
    func removeRefusesTheRoot() {
        let transport = FakeS3Transport()
        #expect(throws: VFSError.self) {
            try backend(transport).removeItem(at: path("/"))
        }
        #expect(transport.writes.isEmpty)
    }

    @Test("deleting a path that is not there fails instead of succeeding emptily")
    func removeMissingPathThrows() {
        let transport = FakeS3Transport()
        transport.listPages = [.ok(S3Fixtures.statMissing)]
        // S3's own DELETE is idempotent (a missing key answers 204), so without this the panel
        // would report a delete of something it never found.
        #expect(throws: VFSError.self) {
            try backend(transport).removeItem(at: path("/nope"))
        }
        #expect(transport.writes.isEmpty)
    }

    // MARK: - Transfer

    @Test("an upload streams the local file to the destination key")
    func uploadsToTheBucket() throws {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(status: 200, bytesTransferred: 4096)
        var reported: Int64 = -1
        try backend(transport).copyFile(
            at: localPath("/tmp/report.pdf"),
            to: path("/docs/report.pdf"),
            progress: { reported = $0 },
            isCancelled: { false }
        )
        #expect(transport.writes == [
            .upload(.init(localPath: "/tmp/report.pdf", key: "docs/report.pdf"))
        ])
        // The count comes from what curl says it sent, not from the local file's size, so a short
        // write reads as a short write.
        #expect(reported == 4096)
    }

    @Test("a copy within the bucket goes server-side — the bytes never come here")
    func copiesWithinTheBucketServerSide() throws {
        let transport = FakeS3Transport()
        try backend(transport).copyFile(
            at: path("/CHANGELOG"),
            to: path("/backup/CHANGELOG"),
            progress: { _ in },
            isCancelled: { false }
        )
        #expect(transport.writes == [
            .copy(.init(sourceKey: "CHANGELOG", destinationKey: "backup/CHANGELOG"))
        ])
        #expect(transport.downloads.isEmpty)
    }

    @Test("a copy to a third backend is refused rather than routed through this machine")
    func refusesUnrelatedBackends() {
        let transport = FakeS3Transport()
        let other = VFSPath(backend: VFSBackendID("sftp://u@h:22"), path: "/x")
        #expect(throws: VFSError.self) {
            try backend(transport).copyFile(
                at: other,
                to: path("/x"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.writes.isEmpty)
    }

    @Test("a refused write is a failure even though curl called it a success")
    func serverRefusalOnAWriteThrows() {
        let transport = FakeS3Transport()
        transport.writeResponse = S3Response(
            status: 403,
            body: Data(S3Fixtures.invalidAccessKey.utf8)
        )
        #expect(throws: VFSError.self) {
            try backend(transport).createDirectory(at: path("/docs"))
        }
    }

    @Test("a path from another connection never reaches the wire")
    func refusesForeignPaths() {
        let transport = FakeS3Transport()
        let elsewhere = S3Location(
            host: "s3.us-east-1.amazonaws.com",
            bucket: "someone-elses",
            region: "us-east-1",
            accessKeyID: "AKIAOTHER"
        )
        #expect(throws: VFSError.self) {
            try backend(transport).removeItem(
                at: VFSPath(backend: .s3(elsewhere), path: "/docs")
            )
        }
        #expect(transport.writes.isEmpty)
    }
}
