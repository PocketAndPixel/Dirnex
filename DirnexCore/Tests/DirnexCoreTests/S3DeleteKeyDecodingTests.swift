import Foundation
import Testing

@testable import DirnexCore

/// Which keys a folder delete actually sweeps.
///
/// Its own suite because it is its own subject: `S3BackendWriteTests` asks *how many requests* a
/// delete is and *what a refusal means*, and this asks what the keys in them say. The distinction is
/// the whole of the 2026-08-22 bug — every request was correct, the batch answered 200, and the
/// folder was still there, because the keys had never been decoded from the wire's
/// `application/x-www-form-urlencoded` spelling. S3's delete is idempotent, so keys that never
/// existed come back deleted.
///
/// `S3FolderRenameTests` is the same fault seen from the user's end: a rename is a copy and then
/// this delete, so the folder ended up under both names.
@Suite("S3 — the keys a folder delete sweeps")
struct S3DeleteKeyDecodingTests {
    private func backend(_ transport: FakeS3Transport) -> S3Backend {
        S3Backend(
            location: S3Location(
                host: "s3.eu-north-1.amazonaws.com",
                bucket: "amzn-s3-df",
                region: "eu-north-1",
                accessKeyID: "AKIAEXAMPLE"
            ),
            transport: transport
        )
    }

    private func path(_ path: String) -> VFSPath {
        VFSPath(
            backend: .s3(S3Location(
                host: "s3.eu-north-1.amazonaws.com",
                bucket: "amzn-s3-df",
                region: "eu-north-1",
                accessKeyID: "AKIAEXAMPLE"
            )),
            path: path
        )
    }

    /// A folder holding a name with a **space** — the 2026-08-22 report, and the one shape every
    /// existing test in this section is blind to.
    ///
    /// The sweep's keys arrive exactly as the wire spelled them, and under `encoding-type=url` that
    /// is `application/x-www-form-urlencoded`. Undecoded they went straight into `DeleteObjects` as
    /// `untitled+folder/…` — keys that have never existed — and S3's delete is idempotent, so the
    /// request answered success, `<Quiet>` left the body empty, no `<Error>` row was there to find,
    /// and the folder was still on screen afterwards.
    ///
    /// It reached the user as a **rename**: `moveItem` answers `EXDEV` for a prefix, `CopyEngine`
    /// copies the tree and then calls this to remove the source, so the folder ended up under both
    /// names (`S3FolderRenameTests` drives that end to end). F8 on the same folder had been silently
    /// deleting nothing since the backend shipped.
    @Test("a folder whose keys need decoding is deleted by its real keys, not the wire's")
    func removeFolderDecodesTheSweptKeys() throws {
        let transport = FakeS3Transport()
        transport.listPages = [
            .ok(S3EncodedKeyFixtures.statSpacedFolder),
            .ok(S3EncodedKeyFixtures.spacedFolderSweep)
        ]
        transport.deleteBatchResponses = [.ok(S3Fixtures.deleteQuiet)]
        try backend(transport).removeItem(at: path("/untitled folder"))

        #expect(transport.writes == [
            .deleteBatch([
                "untitled folder/",
                "untitled folder/файл.txt",
                "untitled folder/sub dir/DSC_0004.NEF"
            ])
        ])
    }

    /// The control that keeps the decode from being applied blind: the same `+` bytes from an
    /// endpoint that ignores `encoding-type` and never echoes it are a **literal plus**, and
    /// decoding them would delete keys that do not exist — the shipped bug, mirrored.
    @Test("an endpoint that declares no encoding has its keys deleted verbatim")
    func removeFolderKeepsRawKeysWhenNothingIsDeclared() throws {
        let transport = FakeS3Transport()
        transport.listPages = [
            .ok(S3EncodedKeyFixtures.statPlusFolderUndeclared),
            .ok(S3EncodedKeyFixtures.plusKeySweepUndeclared)
        ]
        transport.deleteBatchResponses = [.ok(S3Fixtures.deleteQuiet)]
        try backend(transport).removeItem(at: path("/a+b"))

        #expect(transport.writes == [.deleteBatch(["a+b/", "a+b/plus+file.txt"])])
    }

    /// A key nothing can name stops the delete rather than being skipped — the opposite of what a
    /// *listing* does with the same row, and deliberately so: a dropped row is a name nobody can
    /// show, a dropped key is a file left behind under a folder reported as gone.
    @Test("a key that does not decode fails the delete instead of being swept past")
    func removeFolderRefusesAnUndecodableKey() {
        let transport = FakeS3Transport()
        transport.listPages = [
            .ok(S3Fixtures.statDocsFolder),
            .ok(S3EncodedKeyFixtures.undecodableKeySweep)
        ]

        #expect {
            try backend(transport).removeItem(at: path("/docs"))
        } throws: { error in
            guard case let VFSError.io(target, code) = error else { return false }
            return target == path("/docs") && code == EILSEQ
        }
        // Nothing was deleted — the refusal comes before the first batch, so a partial sweep cannot
        // leave the folder half-removed.
        #expect(transport.writes.isEmpty)
    }
}
