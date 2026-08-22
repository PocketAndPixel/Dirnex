import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// End-to-end SFTP browse *and write* against a real server, exercising the actual
/// `SFTPProcessTransport` (spawning `sftp`) → `SFTPBackend` → `SFTPListingParser` chain, including a
/// mkdir/upload/download/recursive-remove round trip. Gated on a config file so it never runs in CI
/// (which has no server): drop a JSON file at `/tmp/dirnex_sftp_live_test.json` with
/// `{ "host": …, "port": 22, "user": …, "identityFile": …, "remotePath": … }` for a reachable
/// key-auth account (a file, not env vars, because `xcodebuild` doesn't forward the shell
/// environment to the test runner). Without the file the suite is skipped.
@Suite("SFTP live integration", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SFTPLiveIntegrationTests {
    private func makeBackend() throws -> (SFTPBackend, SFTPLiveEnvironment.Config) {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        return (SFTPBackend(location: config.location, transport: transport), config)
    }

    @Test("resolves the remote home directory (proves auth + connection)")
    func resolvesHome() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let transport = SFTPProcessTransport(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        let home = try transport.resolveHomeDirectory()
        #expect(home.hasPrefix("/"))
    }

    @Test("lists a real remote directory into FileEntry rows under the sftp backend")
    func listsRemoteDirectory() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let entries = try backend.listDirectory(at: path)

            #expect(!entries.isEmpty)
            // The `.`/`..` self/parent rows are dropped; every child carries the sftp backend id.
            #expect(!entries.contains { $0.name == "." || $0.name == ".." })
            for entry in entries {
                #expect(entry.path.backend == .sftp(config.location))
                #expect(entry.path == path.appending(entry.name))
            }
        }
    }

    @Test("stats the queried directory as a directory")
    func statsRemoteDirectory() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let entry = try backend.stat(at: path)
            #expect(entry.isDirectory)
            #expect(entry.path == path)
        }
    }

    @Test("browses through CompositeBackend routing after connectSFTP")
    func browsesThroughCompositeBackend() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let config = try #require(SFTPLiveEnvironment.current)
            let composite = CompositeBackend(local: LocalBackend())
            composite.connectSFTP(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            let path = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            // The composite must route the sftp path to the connection registered above (not the local
            // backend) and report its writable-but-Trash-less capabilities.
            #expect(composite.capabilities(for: path) == [.read, .write, .rename])
            let entries = try composite.listDirectory(at: path)
            #expect(!entries.isEmpty)
        }
    }

    @Test("round-trips a write end-to-end: mkdir → upload → list → download → recursive remove")
    func writeRoundTrip() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            // A unique scratch subtree under the remote path so a stray run never clobbers real data.
            let dir = base.appending("dirnex_write_test_\(UUID().uuidString)")

            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("dirnex_sftp_\(UUID().uuidString)")
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            let localSource = scratch.appendingPathComponent("hello.txt")
            let payload = Data("hello over sftp \(UUID().uuidString)".utf8)
            try payload.write(to: localSource)

            // mkdir on the remote, then upload the local file into it.
            try backend.createDirectory(at: dir)
            let remoteFile = dir.appending("hello.txt")
            try backend.copyFile(
                at: .local(localSource.path),
                to: remoteFile,
                progress: { _ in },
                isCancelled: { false }
            )

            // Listing the new remote directory shows the upload with its true size.
            let listed = try backend.listDirectory(at: dir)
            let uploaded = try #require(listed.first { $0.name == "hello.txt" })
            #expect(uploaded.byteSize == Int64(payload.count))

            // Download it back and confirm the bytes survived the round trip.
            let localDest = scratch.appendingPathComponent("roundtrip.txt")
            try backend.copyFile(
                at: remoteFile,
                to: .local(localDest.path),
                progress: { _ in },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: localDest) == payload)

            // Recursive remove empties and deletes the subtree; the directory is gone afterwards.
            try backend.removeItem(at: dir)
            #expect(throws: (any Error).self) {
                try backend.listDirectory(at: dir)
            }
        }
    }

    /// ⇧F4 "Edit File…" end to end: the empty file really lands on the server, an occupied name is
    /// really refused, and — the half no fake can reach — a name held by a **directory** is refused
    /// rather than silently filled.
    ///
    /// That last case is why this is a live test and not another double. `sftp`'s `put` aimed at an
    /// existing directory exits **0** having created `<directory>/<the local file's basename>`
    /// (measured 2026-08-23), so the failure a missing guard produces is not an error at all: it is
    /// a scratch file appearing inside a folder, under a name nobody chose, with every layer
    /// reporting success. The assertion that catches it is the directory being **empty afterwards**,
    /// which is a claim only a real server can answer.
    @Test("creates an empty file, and refuses a name a file or a directory already holds")
    func createsEmptyFile() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let dir = base.appending("dirnex_create_test_\(UUID().uuidString)")
            try backend.createDirectory(at: dir)
            defer { try? backend.removeItem(at: dir) }

            // A free name is created, empty, and is a *file*.
            let file = dir.appending("notes.txt")
            try backend.createFile(at: file)
            let created = try backend.stat(at: file)
            #expect(created.kind == .file)
            #expect(created.byteSize == 0)

            // The same name again is refused — and, crucially, the existing file is still there
            // rather than truncated, since `put` would have replaced it perfectly happily.
            #expect(throws: VFSError.alreadyExists(file)) {
                try backend.createFile(at: file)
            }

            // A name held by a directory is refused, and nothing is written *into* that directory.
            let occupied = dir.appending("photos")
            try backend.createDirectory(at: occupied)
            #expect(throws: VFSError.alreadyExists(occupied)) {
                try backend.createFile(at: occupied)
            }
            #expect(try backend.listDirectory(at: occupied).isEmpty)
        }
    }

    /// A `mkdir` for a name that is taken must answer `.alreadyExists`, which OpenSSH does **not**
    /// say: its refusal is a bare `remote mkdir "…": Failure` (SFTP v3 has no such status), so the
    /// backend disambiguates with a `stat`. Live because the whole point is what the real server
    /// puts on the wire — a fake can only replay a string somebody typed.
    @Test("a directory name that is taken answers alreadyExists")
    func createDirectoryRefusesATakenName() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let dir = base.appending("dirnex_mkdir_test_\(UUID().uuidString)")
            try backend.createDirectory(at: dir)
            defer { try? backend.removeItem(at: dir) }

            #expect(throws: VFSError.alreadyExists(dir)) {
                try backend.createDirectory(at: dir)
            }
            // The narrowness control, live: a refusal that is *not* about the name keeps its own
            // error, so a missing parent must still read as missing rather than as a collision.
            let orphan = dir.appending("no_such_parent/child")
            #expect(throws: VFSError.notFound(orphan)) {
                try backend.createDirectory(at: orphan)
            }
        }
    }

    @Test("resumes a partial transfer both ways: put -a then get -a reconstruct the whole file")
    func resumesPartialTransfer() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (_, config) = try makeBackend()
            let transport = SFTPProcessTransport(
                location: config.location,
                authentication: .key(identityFile: config.identityFile)
            )
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let remote = base.appending("dirnex_resume_test_\(UUID().uuidString).bin").path

            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("dirnex_resume_\(UUID().uuidString)")
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: scratch)
                try? transport.removeFile(remote)
            }

            // A known 300-byte payload, and a 120-byte prefix standing in for an interrupted transfer.
            let full = Data((0..<300).map { UInt8($0 % 256) })
            let prefix = full.prefix(120)
            let localFull = scratch.appendingPathComponent("full.bin")
            let localPrefix = scratch.appendingPathComponent("prefix.bin")
            try full.write(to: localFull)
            try Data(prefix).write(to: localPrefix)

            // Upload the prefix, then resume with the full file: `put -a` sends only bytes 120…300.
            try transport.upload(
                localPrefix.path, to: remote, resume: false, progress: { _ in },
                isCancelled: { false }
            )
            try transport.upload(
                localFull.path, to: remote, resume: true, progress: { _ in }, isCancelled: { false }
            )

            // Download resume: a local 120-byte partial is filled to 300 by `get -a`, and the progress
            // it reports is the remainder rather than the whole file — the watch's baseline is the
            // partial that was already there.
            let localDownload = scratch.appendingPathComponent("download.bin")
            try Data(prefix).write(to: localDownload)
            var streamed: Int64 = 0
            try transport.download(
                remote,
                to: localDownload.path,
                resume: true,
                progress: { streamed += $0 },
                isCancelled: { false }
            )
            #expect(try Data(contentsOf: localDownload) == full)
            #expect(streamed <= 180, "a resume reports the 180 bytes it moved, never the whole 300")
        }
    }

    @Test("maps a missing remote path to VFSError.notFound")
    func missingPathIsNotFound() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let missing = VFSPath(
                backend: .sftp(config.location),
                path: config.remotePath + "/dirnex_definitely_missing_xyz"
            )
            #expect(throws: VFSError.notFound(missing)) {
                try backend.listDirectory(at: missing)
            }
        }
    }

    // MARK: - The subtree shortcut (M22 Slice 4)

    /// The whole slice, end to end against a real server: one SSH exec channel, one `find`, and
    /// every depth of the tree comes back — where the walk beside it opens a connection per
    /// directory.
    ///
    /// It builds its own three-level scratch tree rather than searching whatever the account
    /// happens to hold, so the assertion is about rows this test put there.
    @Test("one exec channel answers a whole subtree that a walk would pay per directory for")
    func subtreeShortcutAnswersEveryDepth() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let root = base.appending("dirnex_m22_\(UUID().uuidString.prefix(8))")
            let docs = root.appending("docs")
            let sub = docs.appending("sub")
            try backend.createDirectory(at: root)
            defer { try? backend.removeItem(at: root) }
            try backend.createDirectory(at: docs)
            try backend.createDirectory(at: sub)

            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex_m22_notes.txt")
            try Data("note".utf8).write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            try backend.copyFile(
                at: .local(local.path),
                to: sub.appending("notes.txt"),
                progress: { _ in },
                isCancelled: { false }
            )

            let listing = try #require(
                try backend.subtreeListing(at: root, isCancelled: { false })
            )

            // Shallowest first — `find` itself prints depth-first, so this is the ordering the backend
            // applies rather than the server's own.
            #expect(listing.entries.map(\.name) == ["docs", "sub", "notes.txt"])
            #expect(listing.entries.map(\.isDirectory) == [true, true, false])
            #expect(listing.isComplete)
            #expect(listing.entries.last?.byteSize == 4)
            #expect(listing.entries.last?.path == sub.appending("notes.txt"))
        }
    }

    /// The two routes have to agree, or the shortcut is a second definition of what is in a folder.
    /// Compared as *sets* of paths, since the walk's order is breadth-first by construction and the
    /// shortcut's is a sort — the claim is that they see the same tree, not that they say it the
    /// same way.
    @Test("the shortcut and the walk see the same tree")
    func shortcutAgreesWithTheWalk() async throws {
        // Off the cooperative pool: every verb below blocks on a subprocess for a real network
        // round trip, which a test body may not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let (backend, config) = try makeBackend()
            let base = VFSPath(backend: .sftp(config.location), path: config.remotePath)
            let root = base.appending("dirnex_m22cmp_\(UUID().uuidString.prefix(8))")
            try backend.createDirectory(at: root)
            defer { try? backend.removeItem(at: root) }
            try backend.createDirectory(at: root.appending("a"))
            try backend.createDirectory(at: root.appending("a/b"))
            try backend.createDirectory(at: root.appending("c"))

            let shortcut = try #require(try backend.subtreeListing(at: root, isCancelled: { false }))
            // `WalkOnlyBackend` withholds the shortcut so the same backend answers the same question the
            // long way — a negative control that needs no second account.
            let walked = try SubtreeSearch.find(
                under: root,
                using: WalkOnlySFTPBackend(backend),
                matching: try SearchPredicate(FileQuery(), answering: .listed)
            )

            #expect(Set(shortcut.entries.map(\.path.path)) == Set(walked.hits.map(\.path.path)))
            #expect(walked.directoriesListed == 4) // root, a, a/b, c — the requests the shortcut saved
        }
    }
}

/// An `SFTPBackend` with its subtree shortcut withheld, so a live test can ask the same server the
/// same question the slow way and compare. Everything else is forwarded untouched.
private struct WalkOnlySFTPBackend: VFSBackend {
    private let wrapped: SFTPBackend

    init(_ wrapped: SFTPBackend) { self.wrapped = wrapped }

    var id: VFSBackendID { wrapped.id }
    var capabilities: VFSCapabilities { wrapped.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try wrapped.listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try wrapped.stat(at: path) }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        nil
    }
}

/// Reads the live-SFTP test coordinates from a well-known JSON file; `nil` disables the suite.
enum SFTPLiveEnvironment {
    struct Config {
        let location: SFTPLocation
        let identityFile: String
        let remotePath: String
    }

    /// The opt-in config path. A file here turns the suite on; its absence keeps it off in CI.
    static let configPath = "/tmp/dirnex_sftp_live_test.json"

    private struct File: Decodable {
        let host: String
        let port: Int?
        let user: String
        let identityFile: String
        let remotePath: String
    }

    static var current: Config? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return Config(
            location: SFTPLocation(
                host: file.host,
                port: file.port ?? SFTPLocation.defaultPort,
                username: file.user
            ),
            identityFile: file.identityFile,
            remotePath: file.remotePath
        )
    }
}
