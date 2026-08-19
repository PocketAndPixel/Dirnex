import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Reading and editing a remote file in place, end to end against a real endpoint
/// (PLAN.md §M21 Slice 10): download → the copy on disk holds the object's bytes → edit it → upload
/// → an **independent** read sees the edit. Plus the conflict path, driven by mutating the object
/// between the download and the save.
///
/// It exists because every claim here is about bytes crossing a network, and the headless suites
/// deliberately cannot see that: `RemoteFileCacheTests` proves the cache's *rules* against a fake
/// that writes known bytes, which says nothing about whether a real signed `PUT` carries an edit
/// back. The two are complementary and neither substitutes for the other.
///
/// **The verification read is built separately from the write.** A save-then-read through the same
/// `RemoteFileCache` would prove the cache agrees with itself — the trap Slice 10's own probe 4 fell
/// into, where re-typing the name it had just uploaded was blind to Slice 8's trim by construction.
/// So the check is a fresh `stat` plus a fresh download into a directory the cache does not own.
///
/// Gated on the same config file as the account suite, and `.serialized` for the same two reasons:
/// one endpoint, and one Keychain item.
@Suite(
    "Remote file edit live integration",
    .serialized,
    .enabled(if: S3LiveEnvironment.current != nil)
)
@MainActor
final class RemoteFileEditLiveIntegrationTests {
    // MARK: - Fixtures

    private func backend(_ config: S3LiveEnvironment.Config) -> S3Backend {
        let location = config.account.bucketLocation(named: config.bucket)
        return S3Backend(
            location: location,
            transport: S3CurlTransport(
                location: location, secretAccessKey: config.secretAccessKey
            )
        )
    }

    /// A scratch key under a prefix of this suite's own, so a failed run leaves nothing that looks
    /// like somebody's data.
    private func scratchKey(_ name: String) -> String {
        "dirnex-live-probe/slice10/\(name)"
    }

    /// Put `contents` at `key` and hand back the entry the *listing* reports for it.
    ///
    /// The entry comes from `stat` rather than being built here, because the whole point is that
    /// every later request addresses the object through the name the server produced — the way the
    /// app does. A hand-built path would be on neither side of the round trip under test.
    private func upload(
        _ contents: String,
        to key: String,
        using backend: S3Backend
    ) async throws -> FileEntry {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice10-\(UUID().uuidString)")
        try Data(contents.utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let remote = VFSPath(backend: backend.id, path: "/\(key)")
        try await BlockingWork.run { () -> Result<Void, any Error> in
            Result {
                try backend.copyFile(
                    at: .local(local.path), to: remote, progress: { _ in }, isCancelled: { false }
                )
            }
        }.get()
        return try await BlockingWork.run { Result { try backend.stat(at: remote) } }.get()
    }

    /// Read `path` back through a fresh transfer of its own, into a directory the cache never sees.
    private func independentRead(
        of path: VFSPath,
        using backend: S3Backend
    ) async throws -> String {
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("slice10-verify-\(UUID().uuidString)")
        try await BlockingWork.run { () -> Result<Void, any Error> in
            Result {
                try backend.copyFile(
                    at: path, to: .local(local.path), progress: { _ in }, isCancelled: { false }
                )
            }
        }.get()
        defer { try? FileManager.default.removeItem(at: local) }
        return try String(contentsOf: local, encoding: .utf8)
    }

    private func remove(_ path: VFSPath, using backend: S3Backend) async {
        _ = await BlockingWork.run { Result { try backend.removeItem(at: path) } }
    }

    // MARK: - Download → edit → upload → verify

    @Test("an edited copy of a remote file uploads back, and an independent read sees the edit")
    func editRoundTrips() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let backend = backend(config)
        let key = scratchKey("round-trip.txt")
        let entry = try await upload("before", to: key, using: backend)
        defer { Task { await remove(entry.path, using: backend) } }

        // The download the preview, ⏎ and F4 all share.
        let cache = RemoteFileCache()
        let copy = try await cache.fetch(
            entry, using: backend, progress: { _ in }, isCancelled: { false }
        )
        #expect(try String(contentsOf: copy, encoding: .utf8) == "before")

        // The editor's save, in the only form that matters here: different bytes at the same path.
        try Data("after".utf8).write(to: copy)

        try await BlockingWork.run { () -> Result<Void, any Error> in
            Result {
                try backend.copyFile(
                    at: .local(copy.path),
                    to: entry.path,
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }.get()

        #expect(try await independentRead(of: entry.path, using: backend) == "after")
    }

    /// A key with edge whitespace, because download-and-upload are two more verbs that build a URL
    /// from a name — the class of bug Slice 8 shipped, where `stat` went on agreeing with the
    /// listing while every byte-moving verb addressed a different object (docs/NOTES.md ▸ curl for
    /// S3). Addressed through the *listing's* own path throughout, which is what makes it able to
    /// see the trim at all.
    @Test("a key with a trailing space round-trips through download and upload")
    func edgeWhitespaceKeyRoundTrips() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let backend = backend(config)
        let key = scratchKey("trailing ")
        let entry = try await upload("before", to: key, using: backend)
        defer { Task { await remove(entry.path, using: backend) } }

        // The tell that the trim is gone: the name the listing produced still carries its space.
        #expect(entry.path.path.hasSuffix("trailing "))

        let cache = RemoteFileCache()
        let copy = try await cache.fetch(
            entry, using: backend, progress: { _ in }, isCancelled: { false }
        )
        try Data("after".utf8).write(to: copy)
        try await BlockingWork.run { () -> Result<Void, any Error> in
            Result {
                try backend.copyFile(
                    at: .local(copy.path),
                    to: entry.path,
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }.get()

        #expect(try await independentRead(of: entry.path, using: backend) == "after")
    }

    // MARK: - The conflict path

    /// The hazard the whole write-back mechanism exists for: somebody else writes the object between
    /// the download and the save. Driven by actually mutating it, not by fabricating a revision —
    /// what is under test is that a real endpoint's `stat` reports the change in time to be read,
    /// which is the read-after-write assumption Slice 10's probe 3 measured and this pins.
    @Test("an object rewritten between the download and the save is reported as a conflict")
    func concurrentWriteIsDetected() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let backend = backend(config)
        let key = scratchKey("conflict.txt")
        let entry = try await upload("before", to: key, using: backend)
        defer { Task { await remove(entry.path, using: backend) } }

        let cache = RemoteFileCache()
        _ = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })
        let recorded = try #require(cache.revision(for: entry.path))

        // Somebody else's write. A different length, so the change is visible to the weakest
        // evidence this check can rest on.
        _ = try await upload("somebody else's much longer text", to: key, using: backend)

        let current = try await BlockingWork.run {
            Result { try backend.stat(at: entry.path) }
        }.get()
        #expect(recorded.isSuperseded(by: RemoteFileRevision(current)))

        // And the sentence the user would read is the one that names it, rather than the one that
        // says everything is fine.
        let body = BrowserWindowController.writeBackBody(
            recorded: recorded, current: RemoteFileRevision(current)
        )
        #expect(body != BrowserWindowController.writeBackBody(
            recorded: recorded, current: recorded
        ))
    }

    /// The other half, and the one that stops the check from being "always warn", which would train
    /// the user to click through it: an untouched object must come back clean.
    @Test("an untouched object is not reported as a conflict")
    func untouchedObjectIsNotAConflict() async throws {
        let config = try #require(S3LiveEnvironment.current)
        let backend = backend(config)
        let key = scratchKey("quiet.txt")
        let entry = try await upload("before", to: key, using: backend)
        defer { Task { await remove(entry.path, using: backend) } }

        let cache = RemoteFileCache()
        _ = try await cache.fetch(entry, using: backend, progress: { _ in }, isCancelled: { false })
        let recorded = try #require(cache.revision(for: entry.path))

        let current = try await BlockingWork.run {
            Result { try backend.stat(at: entry.path) }
        }.get()
        #expect(!recorded.isSuperseded(by: RemoteFileRevision(current)))
        // The strongest answer there is: both readings carried an entity tag and the tags matched,
        // so this is proof of sameness rather than an absence of evidence. It reads
        // `.sizeAndTimestamp` — still true, and weaker — for as long as nothing supplies a tag,
        // which is what this endpoint settled: it sends `<ETag>` on every `ListObjectsV2` row, so
        // the tag rides in on the same request the row is built from and no verb pays for it.
        #expect(recorded.evidence(comparedWith: RemoteFileRevision(current)) == .entityTag)
        // Held separately, because the assertion above would also pass if *neither* side had one
        // and the case had been mis-ordered: the tag is really there, and it is the object's own.
        #expect(recorded.entityTag != nil)
        #expect(recorded.entityTag == RemoteFileRevision(current).entityTag)
    }
}
