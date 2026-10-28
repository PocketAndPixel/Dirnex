import Foundation
import Testing

@testable import DirnexCore

/// The content check behind a remote write-back (PLAN.md §M34 ▸ 2026-10-27, the content check).
///
/// The fake server lists every file at one fixed minute, whenever its bytes last changed, which is
/// what an SFTP `ls -la` row does inside a minute. So the size and time say "unchanged" for any
/// same-size rewrite, and only the bytes can tell. Every test also counts the downloads, since the
/// check's other promise is that it fetches nothing where the size and time already answered.
@Suite("Write-back content check")
struct WriteBackContentCheckTests {
    private static let original = "Hello\nGoodbye\n"
    private static let rewritten = "Hello\nSee you\n"

    /// A base holding `contents`, as `EditBaseStore` keeps one.
    private func base(_ contents: String, in tree: TempTree) throws -> URL {
        URL(fileURLWithPath: try tree.writeFile("base.txt", contents: contents))
    }

    private func scratch(in tree: TempTree) throws -> URL {
        URL(fileURLWithPath: try tree.makeDir("scratch"))
    }

    private func scratchIsEmpty(in tree: TempTree) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: tree.path("scratch")).isEmpty
    }

    private func verdict(
        recorded: RemoteFileRevision?,
        current: FileEntry?,
        base: URL?,
        previewLimit: Int64 = RemoteFetchPolicy.defaultPreviewLimit,
        server: MinuteServer,
        tree: TempTree
    ) throws -> WriteBackContentVerdict {
        WriteBackContentCheck(
            backend: server, previewLimit: previewLimit, scratch: try scratch(in: tree)
        ).verdict(recorded: recorded, current: current, base: base)
    }

    // MARK: - The case it exists for

    /// The overwrite seen live on 2026-10-27: the server's file went from "Goodbye" to "See you",
    /// the same 14 bytes in the same minute. The first two expectations are the blind spot itself,
    /// and the third is the check seeing through it.
    @Test("a same-size rewrite in the same minute is caught by the bytes")
    func sameSizeSameMinuteRewriteIsCaught() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(server.entry("/notes.txt"))
        let base = try base(Self.original, in: tree)
        server.write("/notes.txt", Self.rewritten)
        let current = server.entry("/notes.txt")

        #expect(!recorded.isSuperseded(by: RemoteFileRevision(current)))
        #expect(recorded.matchesOnlyBySizeAndTime(RemoteFileRevision(current)))
        let found = try verdict(
            recorded: recorded, current: current, base: base, server: server, tree: tree
        )
        #expect(found == .different)
        #expect(found.isChange)
        #expect(server.fetches == 1)
    }

    /// The other half, and the common one: nobody wrote, so the save goes up with nothing asked.
    @Test("a server still holding the base's bytes is the same")
    func untouchedServerIsTheSame() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let current = server.entry("/notes.txt")

        let found = try verdict(
            recorded: RemoteFileRevision(current),
            current: current,
            base: try base(Self.original, in: tree),
            server: server,
            tree: tree
        )

        #expect(found == .same)
        #expect(!found.isChange)
        #expect(server.fetches == 1)
    }

    /// Somebody rewrote the file with the bytes it already held. An upload over it loses nothing, so
    /// the check has nothing to ask, though a size and time that moved would have asked.
    @Test("the same bytes written again are the same")
    func identicalRewriteIsTheSame() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(server.entry("/notes.txt"))
        server.write("/notes.txt", Self.original)

        let found = try verdict(
            recorded: recorded,
            current: server.entry("/notes.txt"),
            base: try base(Self.original, in: tree),
            server: server,
            tree: tree
        )

        #expect(found == .same)
    }

    // MARK: - Nothing fetched where the stat answered

    @Test("a size difference is the stat's to settle, and nothing is fetched")
    func sizeDifferenceFetchesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(server.entry("/notes.txt"))
        server.write("/notes.txt", "Hello\nSee you later\n")

        let found = try verdict(
            recorded: recorded,
            current: server.entry("/notes.txt"),
            base: try base(Self.original, in: tree),
            server: server,
            tree: tree
        )

        #expect(found == .notAsked)
        #expect(server.fetches == 0)
    }

    /// WebDAV and S3 carry entity tags, which settle it either way, so their saves pay for no
    /// download. A tag on one side only proves nothing, and the bytes are asked.
    @Test("tags on both sides settle it without a fetch, and a tag on one side does not")
    func tagsOnBothSidesFetchNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let base = try base(Self.original, in: tree)
        let tagged = RemoteFileRevision(server.entry("/notes.txt", tag: "\"aaa\""))

        let matching = try verdict(
            recorded: tagged, current: server.entry("/notes.txt", tag: "\"aaa\""),
            base: base, server: server, tree: tree
        )
        #expect(matching == .notAsked)
        #expect(server.fetches == 0)

        let untagged = try verdict(
            recorded: tagged, current: server.entry("/notes.txt"),
            base: base, server: server, tree: tree
        )
        #expect(untagged == .same)
        #expect(server.fetches == 1)
    }

    /// No record and a failed re-`stat` are the write-back's own questions, asked in its own words;
    /// the bytes have nothing to add to either.
    @Test("a missing reading is not asked, and nothing is fetched")
    func missingReadingFetchesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let entry = server.entry("/notes.txt")
        let base = try base(Self.original, in: tree)

        let noRecord = try verdict(
            recorded: nil, current: entry, base: base, server: server, tree: tree
        )
        let noReading = try verdict(
            recorded: RemoteFileRevision(entry), current: nil, base: base, server: server,
            tree: tree
        )

        #expect(noRecord == .notAsked)
        #expect(noReading == .notAsked)
        #expect(server.fetches == 0)
    }

    @Test("a copy with no base is not compared, and nothing is fetched")
    func noBaseFetchesNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let entry = server.entry("/notes.txt")

        let found = try verdict(
            recorded: RemoteFileRevision(entry), current: entry, base: nil, server: server,
            tree: tree
        )

        #expect(found == .noBase)
        #expect(server.fetches == 0)
    }

    // MARK: - The limit

    /// The Settings limit is inclusive, as every row of the fetch table is, and zero means no file
    /// with bytes in it comes down.
    @Test("a file past the Settings limit is not fetched, and one at it is")
    func limitBoundsTheFetch() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let entry = server.entry("/notes.txt")
        let base = try base(Self.original, in: tree)
        let size = entry.byteSize

        let past = try verdict(
            recorded: RemoteFileRevision(entry), current: entry, base: base,
            previewLimit: size - 1, server: server, tree: tree
        )
        let off = try verdict(
            recorded: RemoteFileRevision(entry), current: entry, base: base,
            previewLimit: 0, server: server, tree: tree
        )
        #expect(past == .overLimit)
        #expect(off == .overLimit)
        #expect(server.fetches == 0)

        let at = try verdict(
            recorded: RemoteFileRevision(entry), current: entry, base: base,
            previewLimit: size, server: server, tree: tree
        )
        #expect(at == .same)
        #expect(server.fetches == 1)
    }

    // MARK: - What it leaves behind

    @Test("a failed fetch is unreadable and leaves nothing in the scratch directory")
    func failedFetchIsUnreadable() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let entry = server.entry("/notes.txt")
        server.failsFetches = true

        let found = try verdict(
            recorded: RemoteFileRevision(entry),
            current: entry,
            base: try base(Self.original, in: tree),
            server: server,
            tree: tree
        )

        #expect(found == .unreadable)
        #expect(!found.isChange)
        #expect(try scratchIsEmpty(in: tree))
    }

    /// The server's bytes are needed only for the comparison, so they go whatever it found. The base
    /// is the caller's and stays.
    @Test("the server's bytes are removed after the comparison, and the base is kept")
    func downloadIsRemoved() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(server.entry("/notes.txt"))
        let base = try base(Self.original, in: tree)

        let same = try verdict(
            recorded: recorded, current: server.entry("/notes.txt"), base: base,
            server: server, tree: tree
        )
        #expect(same == .same)
        #expect(try scratchIsEmpty(in: tree))

        server.write("/notes.txt", Self.rewritten)
        let different = try verdict(
            recorded: recorded, current: server.entry("/notes.txt"), base: base,
            server: server, tree: tree
        )
        #expect(different == .different)
        #expect(try scratchIsEmpty(in: tree))
        #expect(try String(contentsOf: base, encoding: .utf8) == Self.original)
    }
}

/// A server that lists every file at one minute, whenever it was written, with no entity tag unless
/// a test asks for one: an SFTP `ls -la` row inside a minute.
private final class MinuteServer: VFSBackend, @unchecked Sendable {
    private static let minute = Date(timeIntervalSince1970: 1_793_092_500)
    private let lock = NSLock()
    private var files: [String: String]
    private var fetchCount = 0
    private var failing = false

    init(files: [String: String]) {
        self.files = files
    }

    var id: VFSBackendID { VFSBackendID("test-minute://host") }
    var capabilities: VFSCapabilities { [.read, .write] }

    var fetches: Int { lock.withLock { fetchCount } }

    var failsFetches: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    func write(_ path: String, _ contents: String) {
        lock.withLock { files[path] = contents }
    }

    func entry(_ path: String, tag: String? = nil) -> FileEntry {
        let full = VFSPath(backend: id, path: path)
        let size = lock.withLock { files[path]?.utf8.count ?? 0 }
        return FileEntry(
            path: full,
            name: full.lastComponent,
            kind: .file,
            byteSize: Int64(size),
            modificationDate: Self.minute,
            creationDate: Self.minute,
            isHidden: false,
            permissions: 0o644,
            inode: 1,
            entityTag: tag
        )
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let (contents, fails) = lock.withLock {
            fetchCount += 1
            return (files[source.path], failing)
        }
        if fails {
            // A partial first, as an interrupted transfer leaves one, so "leaves nothing" is about
            // the cleanup rather than about never having written.
            try? Data("half".utf8).write(to: URL(fileURLWithPath: destination.path))
            throw VFSError.io(path: source, code: 5)
        }
        guard let contents else { throw VFSError.notFound(source) }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: destination.path))
        progress(Int64(contents.utf8.count))
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard lock.withLock({ files[path.path] }) != nil else { throw VFSError.notFound(path) }
        return entry(path.path)
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
}
