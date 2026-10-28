import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The save's content check against real servers (PLAN.md §M34 ▸ 2026-10-27, the content check).
///
/// The headless suites prove the wiring against a fake that lists every file at one minute. What
/// only a real server can show is that its own answer has the blind spot — a rewrite of the same
/// size **in the same second** lists exactly as the original did, over SFTP's `ls -la` and FTP's
/// `MLSD` alike — and that the reader sees through it with that server's own download. Both rewrites
/// are stamped to one second, so no clock resolution could have told them apart and the run cannot
/// depend on where the minute boundary falls.
///
/// Gated on the throwaway servers' config files, so CI skips them. Read the run's issue count, not
/// the ticks: a body inside ``offCooperativePool`` files its failures under `Test «unknown»`
/// (docs/NOTES.md ▸ Testing).
enum RemoteWriteBackContentLive {
    static let original = "Hello\nGoodbye\n"
    static let rewritten = "Hello\nSee you\n"
    /// The second both versions are stamped to.
    static let stamp = Date(timeIntervalSince1970: 1_793_092_530)

    /// A local file holding `contents`, as `EditBaseStore` keeps a base.
    static func local(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-content-live-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func check(_ backend: any VFSBackend) throws -> WriteBackContentCheck {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-content-scratch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return WriteBackContentCheck(
            backend: backend, previewLimit: RemoteFetchPolicy.defaultPreviewLimit, scratch: scratch
        )
    }

    /// What one run found: the revision recorded, the reading of the untouched file, and the reading
    /// after somebody else's write.
    struct Run: Sendable {
        let recorded: RemoteFileRevision
        let untouched: WriteBackServerReading
        let rewritten: WriteBackServerReading
        let scratchLeft: [String]
    }

    static func read(
        _ destination: VFSPath,
        recorded: RemoteFileRevision,
        base: URL,
        check: WriteBackContentCheck
    ) -> WriteBackServerReading {
        BrowserWindowController.readServer(
            at: [destination], recorded: [recorded], bases: [base], check: check
        )[0]
    }

    /// The assertions both protocols share, on the main actor where the prompt's wording lives.
    @MainActor
    static func expectCaught(_ run: Run) throws {
        #expect(run.untouched.content == .same)
        #expect(BrowserWindowController.writeBackConcern(
            recorded: run.recorded,
            current: run.untouched.entry.map(RemoteFileRevision.init),
            contentChanged: run.untouched.content.isChange
        ) == nil)

        let current = try #require(run.rewritten.entry)
        // The server's own listing cannot see the write: the same size, the same second.
        #expect(!run.recorded.isSuperseded(by: RemoteFileRevision(current)))
        #expect(run.rewritten.content == .different)
        #expect(BrowserWindowController.writeBackConcern(
            recorded: run.recorded,
            current: RemoteFileRevision(current),
            contentChanged: run.rewritten.content.isChange
        ) != nil)
        // And the server's bytes the check brought down went once compared.
        #expect(run.scratchLeft.isEmpty)
    }
}

@Suite("Write-back content check ▸ SFTP live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct RemoteWriteBackContentSFTPLiveTests {
    /// Written on the server's own disk, since the server is this Mac, and read only through the
    /// real `sftp` transport.
    @Test("a same-size rewrite in the same second is caught by the bytes, over SFTP")
    func sameSecondRewriteIsCaught() async throws {
        let run = try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let backend = SFTPBackend(
                location: config.location,
                transport: SFTPProcessTransport(
                    location: config.location,
                    authentication: .key(identityFile: config.identityFile)
                )
            )
            let onDisk = config.remotePath + "/wb-content-\(UUID().uuidString.prefix(8)).txt"
            defer { try? FileManager.default.removeItem(atPath: onDisk) }
            let write = { (contents: String) in
                try Data(contents.utf8).write(to: URL(fileURLWithPath: onDisk))
                try FileManager.default.setAttributes(
                    [.modificationDate: RemoteWriteBackContentLive.stamp], ofItemAtPath: onDisk
                )
            }
            try write(RemoteWriteBackContentLive.original)
            let destination = VFSPath(backend: .sftp(config.location), path: onDisk)
            let recorded = try RemoteFileRevision(backend.stat(at: destination))
            let base = try RemoteWriteBackContentLive.local(RemoteWriteBackContentLive.original)
            defer { try? FileManager.default.removeItem(at: base) }
            let check = try RemoteWriteBackContentLive.check(backend)
            defer { try? FileManager.default.removeItem(at: check.scratch) }

            let untouched = RemoteWriteBackContentLive.read(
                destination, recorded: recorded, base: base, check: check
            )
            try write(RemoteWriteBackContentLive.rewritten)
            let rewritten = RemoteWriteBackContentLive.read(
                destination, recorded: recorded, base: base, check: check
            )
            return RemoteWriteBackContentLive.Run(
                recorded: recorded,
                untouched: untouched,
                rewritten: rewritten,
                scratchLeft: try FileManager.default.contentsOfDirectory(atPath: check.scratch.path)
            )
        }
        try await RemoteWriteBackContentLive.expectCaught(run)
    }
}

@Suite("Write-back content check ▸ FTP live", .enabled(if: FTPLiveEnvironment.current != nil))
struct RemoteWriteBackContentFTPLiveTests {
    /// Uploaded and stamped through the real transport, `MFMT` included, since the FTP config does
    /// not say where the server keeps its files. pyftpdlib answers `MLSD`, so its listing has the
    /// second, and the one second both versions share is what that cannot see.
    @Test("a same-size rewrite in the same second is caught by the bytes, over FTP")
    func sameSecondRewriteIsCaught() async throws {
        let run = try await offCooperativePool {
            let config = try #require(FTPLiveEnvironment.current)
            let backend = FTPBackend(
                location: config.location,
                transport: FTPCurlTransport(
                    location: config.location,
                    authentication: config.authentication,
                    password: config.password,
                    trustedPublicKey: config.trustedPublicKey
                )
            )
            let destination = VFSPath(backend: .ftp(config.location), path: config.remotePath)
                .appending("wb-content-\(UUID().uuidString.prefix(8)).txt")
            defer { try? backend.removeItem(at: destination) }
            let write = { (contents: String) in
                let local = try RemoteWriteBackContentLive.local(contents)
                defer { try? FileManager.default.removeItem(at: local) }
                try backend.copyFile(
                    at: .local(local.path), to: destination, progress: { _ in },
                    isCancelled: { false }
                )
                let refused = try backend.applyMetadata(
                    [.setModificationTime(RemoteWriteBackContentLive.stamp)], at: destination
                )
                #expect(refused.isEmpty, "MFMT was refused: \(refused)")
            }
            try write(RemoteWriteBackContentLive.original)
            let recorded = try RemoteFileRevision(backend.stat(at: destination))
            // The listing has to carry the stamp to the second, or this run is about LIST's minute.
            #expect(recorded.modified == RemoteWriteBackContentLive.stamp)
            let base = try RemoteWriteBackContentLive.local(RemoteWriteBackContentLive.original)
            defer { try? FileManager.default.removeItem(at: base) }
            let check = try RemoteWriteBackContentLive.check(backend)
            defer { try? FileManager.default.removeItem(at: check.scratch) }

            let untouched = RemoteWriteBackContentLive.read(
                destination, recorded: recorded, base: base, check: check
            )
            try write(RemoteWriteBackContentLive.rewritten)
            let rewritten = RemoteWriteBackContentLive.read(
                destination, recorded: recorded, base: base, check: check
            )
            return RemoteWriteBackContentLive.Run(
                recorded: recorded,
                untouched: untouched,
                rewritten: rewritten,
                scratchLeft: try FileManager.default.contentsOfDirectory(atPath: check.scratch.path)
            )
        }
        try await RemoteWriteBackContentLive.expectCaught(run)
    }
}
