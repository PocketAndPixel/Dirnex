import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A save's check asking the server's bytes where the size and time cannot answer (PLAN.md §M34 ▸
/// 2026-10-27, the content check).
///
/// The core pins the comparison; what is pinned here is the wiring a save goes through: the reader
/// that `stat`s and compares each destination against its copy's own base, and what a reading turns
/// into — the "changed" question, Merge…, or an upload with nothing asked. The fake server lists
/// every file at one minute, as an SFTP `ls -la` row does inside a minute, so a same-size rewrite is
/// invisible to everything but the bytes.
@MainActor
@Suite("Write-back content check")
struct RemoteWriteBackContentTests {
    private static let original = "Hello\nGoodbye\n"
    private static let rewritten = "Hello\nSee you\n"

    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-content-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func check(_ server: MinuteServer, previewLimit: Int64 = 10_000_000) throws
        -> WriteBackContentCheck {
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return WriteBackContentCheck(backend: server, previewLimit: previewLimit, scratch: scratch)
    }

    /// An edited copy of `path`, saved, waiting to go up.
    private func pending(_ server: MinuteServer, _ path: String) throws -> PendingWriteBack {
        let destination = VFSPath(backend: server.id, path: path)
        let copy = try file("copy-\(destination.lastComponent)", "Hello\nGoodbye, all\n")
        return (
            edit: EditedFile(
                destination: .remoteFile(destination), temporaryURL: copy,
                name: destination.lastComponent
            ),
            destination: destination
        )
    }

    private func checked(
        _ batch: [PendingWriteBack],
        recorded: [RemoteFileRevision?],
        readings: [WriteBackServerReading]
    ) -> [CheckedWriteBack] {
        BrowserWindowController.checkedWriteBacks(
            batch,
            recorded: recorded,
            readings: readings,
            sizes: batch.map { _ in 18 },
            mergeBase: nil
        )
    }

    // MARK: - The case it exists for

    /// The overwrite seen live on 2026-10-27, through the save's own wiring: the server's "Goodbye"
    /// became "See you" in the minute of the last upload. The size and time alone say nothing, and
    /// the save asks, with Merge… offered from the base.
    @Test("a same-size write in the same minute asks before the upload, with Merge… offered")
    func sameMinuteRewriteAsks() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(try server.stat(at: server.path("/notes.txt")))
        let base = try file("base.txt", Self.original)
        server.write("/notes.txt", Self.rewritten)
        let save = try pending(server, "/notes.txt")

        let readings = BrowserWindowController.readServer(
            at: [save.destination], recorded: [recorded], bases: [base], check: try check(server)
        )
        let current = try #require(readings[0].entry)

        // The blind spot, against the stat this reading made: the size and time agree.
        #expect(!recorded.isSuperseded(by: RemoteFileRevision(current)))
        #expect(readings[0].content == .different)
        let items = checked([save], recorded: [recorded], readings: readings)
        #expect(items[0].hasConcern)
        // The same sentence a size that moved gets: it is the same fact.
        let sizeMoved = RemoteFileRevision(
            byteSize: current.byteSize + 1,
            modified: recorded.modified
        )
        #expect(items[0].concern == BrowserWindowController.writeBackConcern(
            recorded: recorded, current: sizeMoved
        ))
        #expect(WriteBackBatchPlan.needsConfirmation(items))
        let offered = await BrowserWindowController.mergeBase(
            base,
            yours: save.edit.temporaryURL,
            recorded: recorded,
            current: current,
            contentChanged: readings[0].content.isChange
        )
        #expect(offered == base)
    }

    /// The common case, and the one that keeps the save silent: nobody wrote, so the bytes match the
    /// base and the upload goes with nothing asked.
    @Test("a server still holding the base's bytes uploads with nothing asked")
    func untouchedServerUploads() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(try server.stat(at: server.path("/notes.txt")))
        let base = try file("base.txt", Self.original)
        let save = try pending(server, "/notes.txt")

        let readings = BrowserWindowController.readServer(
            at: [save.destination], recorded: [recorded], bases: [base], check: try check(server)
        )

        #expect(readings[0].content == .same)
        #expect(!WriteBackBatchPlan.needsConfirmation(
            checked([save], recorded: [recorded], readings: readings)
        ))
        let offered = await BrowserWindowController.mergeBase(
            base,
            yours: save.edit.temporaryURL,
            recorded: recorded,
            current: readings[0].entry,
            contentChanged: readings[0].content.isChange
        )
        #expect(offered == nil)
    }

    /// Each file of a batch is read against its own base, in the batch's order, so the one that
    /// changed is the one named and the clean one can still go up with Skip Changed Files.
    @Test("each file of a batch is compared with its own base")
    func batchComparesEachFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = MinuteServer(files: ["/a.txt": Self.original, "/b.txt": Self.original])
        let recorded = try ["/a.txt", "/b.txt"].map {
            RemoteFileRevision(try server.stat(at: server.path($0)))
        }
        let bases = try [file("base-a.txt", Self.original), file("base-b.txt", Self.original)]
        server.write("/b.txt", Self.rewritten)
        let batch = try [pending(server, "/a.txt"), pending(server, "/b.txt")]

        let readings = BrowserWindowController.readServer(
            at: batch.map(\.destination), recorded: recorded, bases: bases, check: try check(server)
        )

        #expect(readings.map(\.content) == [.same, .different])
        let items = checked(batch, recorded: recorded, readings: readings)
        #expect(items.map(\.hasConcern) == [false, true])
        #expect(WriteBackBatchPlan.items(for: .clean, from: items).map(\.destination)
            == [batch[0].destination])
        #expect(server.fetches == 2)
    }

    // MARK: - Where it stands down

    /// No base, or a file past the Settings limit: the save rests on the size and time, as it did
    /// before the check existed, and nothing is downloaded to find that out.
    @Test("with no base, or past the limit, the save rests on the size and time")
    func standsDownWithoutBaseOrOverLimit() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(try server.stat(at: server.path("/notes.txt")))
        let base = try file("base.txt", Self.original)
        server.write("/notes.txt", Self.rewritten)
        let save = try pending(server, "/notes.txt")

        let noBase = BrowserWindowController.readServer(
            at: [save.destination], recorded: [recorded], bases: [nil], check: try check(server)
        )
        let overLimit = BrowserWindowController.readServer(
            at: [save.destination], recorded: [recorded], bases: [base],
            check: try check(server, previewLimit: 4)
        )

        #expect(noBase[0].content == .noBase)
        #expect(overLimit[0].content == .overLimit)
        #expect(server.fetches == 0)
        #expect(!checked([save], recorded: [recorded], readings: noBase)[0].hasConcern)
    }

    /// A file the `stat` could not reach is the check's own question, with nothing for the bytes to
    /// add.
    @Test("a file the stat cannot reach is asked about without a download")
    func unreachableIsAskedWithoutDownload() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = MinuteServer(files: ["/notes.txt": Self.original])
        let recorded = RemoteFileRevision(try server.stat(at: server.path("/notes.txt")))
        let save = try pending(server, "/notes.txt")
        server.remove("/notes.txt")

        let readings = BrowserWindowController.readServer(
            at: [save.destination], recorded: [recorded],
            bases: [try file("base.txt", Self.original)],
            check: try check(server)
        )

        #expect(readings[0].entry == nil)
        #expect(readings[0].content == .notAsked)
        #expect(server.fetches == 0)
        #expect(checked([save], recorded: [recorded], readings: readings)[0].hasConcern)
    }
}

/// A server that lists every file at one minute, whenever it was written, and counts downloads.
private final class MinuteServer: VFSBackend, @unchecked Sendable {
    private static let minute = Date(timeIntervalSince1970: 1_793_092_500)
    private let lock = NSLock()
    private var files: [String: String]
    private var fetchCount = 0

    init(files: [String: String]) {
        self.files = files
    }

    var id: VFSBackendID { VFSBackendID("test-minute://host") }
    var capabilities: VFSCapabilities { [.read, .write] }
    var fetches: Int { lock.withLock { fetchCount } }

    func path(_ path: String) -> VFSPath {
        VFSPath(backend: id, path: path)
    }

    func write(_ path: String, _ contents: String) {
        lock.withLock { files[path] = contents }
    }

    func remove(_ path: String) {
        lock.withLock { files[path] = nil }
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard let contents = lock.withLock({ files[path.path] }) else { throw VFSError.notFound(path) }
        return FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: Int64(contents.utf8.count),
            modificationDate: Self.minute,
            creationDate: Self.minute,
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let contents = lock.withLock {
            fetchCount += 1
            return files[source.path]
        }
        guard let contents else { throw VFSError.notFound(source) }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: destination.path))
        progress(Int64(contents.utf8.count))
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
}
