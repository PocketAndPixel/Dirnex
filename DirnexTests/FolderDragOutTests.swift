import AppKit
import DirnexCore
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// A folder on a server dragged into Finder (PLAN.md §M36 Slice 3, decision B).
///
/// A drag session cannot be synthesized, so what Finder does with a promised folder was measured
/// with a throwaway drag source (probe P1, `RemoteFolderPromise`), and these pin this side of the
/// drop: the promise a folder gets, that fulfilling it queues the staging job and moves the tree to
/// Finder's path, and every way that can end short of that leaving nothing at the path. The failure
/// endings are pinned on `RemoteFolderPromise.settle` rather than through a pane, because a pane
/// reports them with an alert, which with no window runs modally and holds the whole run.
@MainActor
@Suite("Folder drag out")
struct FolderDragOutTests {
    private static let sftp = VFSBackendID("sftp://user@host")

    private struct StubBackend: VFSBackend {
        let id: VFSBackendID = .local
        let capabilities: VFSCapabilities = [.read]

        func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
        func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
    }

    private func folder(_ path: String = "/srv/photos") -> FileEntry {
        FileEntry(
            path: VFSPath(backend: Self.sftp, path: path),
            name: (path as NSString).lastPathComponent,
            kind: .directory,
            byteSize: -1,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 7
        )
    }

    private func pane() -> PanelViewController {
        PanelViewController(
            backend: StubBackend(),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
    }

    // MARK: - The promise

    @Test("a folder on a server is promised to Finder as a folder, and still carries the payload")
    func folderIsPromisedAsAFolder() throws {
        let pane = pane()
        let row = folder()
        let writers = PanelPasteboard.dragWriters(
            for: [row], routes: pane.dragOutRoutes(for: [row]), promisedTo: pane
        )
        let promise = try #require(writers.first as? RemoteFilePromiseProvider)
        // Finder took `public.folder` in probe P1. A type off the name would make `photos.2024` a
        // document of some kind, and Finder would be promised a file.
        #expect(promise.fileType == UTType.folder.identifier)
        #expect(pane.filePromiseProvider(promise, fileNameForType: promise.fileType) == "photos")

        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.folder-promise"))
        board.clearContents()
        #expect(board.writeObjects(writers))
        // Inside Dirnex the drag reads its payload and goes through F5, as it always has.
        #expect(PanelPasteboard.payloads(in: board).map(\.path) == [row.path])
        #expect(PanelPasteboard.fileURLs(in: board).isEmpty)
        let types = try #require(board.types).map(\.rawValue)
        #expect(types.contains("com.apple.pasteboard.promised-file-content-type"))
    }

    // MARK: - Fulfilling it

    @Test("Finder's promise queues the staging job and puts the whole tree where Finder asked")
    func promiseMovesTheStagedTree() async throws {
        let tree = try StagedTree.make()
        let drop = try DropFolder()
        defer { drop.remove() }
        let row = folder()
        let pane = pane()
        let host = StubPanelHost()
        pane.host = host
        host.materializeReport = tree.report(for: row)

        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: row, payload: Data("{}".utf8), delegate: pane
        )
        let url = drop.url.appendingPathComponent("photos")
        pane.filePromiseProvider(provider, writePromiseTo: url) { answered.record($0) }
        await answered.settle()

        #expect(answered.count == 1)
        #expect(answered.error == nil)
        // F5's own job, asked for the folder and nothing else.
        #expect(host.materializedEntries.map { $0.map(\.path) } == [[row.path]])
        #expect(
            try String(contentsOf: url.appendingPathComponent("one.txt"), encoding: .utf8) == "one"
        )
        #expect(
            try String(contentsOf: url.appendingPathComponent("sub/two.txt"), encoding: .utf8) == "two"
        )
        // Moved out of the temp root, holder and all.
        #expect(!FileManager.default.fileExists(atPath: tree.holder.path))
        withExtendedLifetime(host) {}
    }

    /// Stop is the user's own answer, already on screen in the queue bar, so nothing is reported;
    /// Finder is still answered, with an error, so it puts nothing at its path.
    @Test("a stopped staging answers Finder and leaves nothing at its path or in the temp root")
    func stoppedStagingLeavesNothing() async throws {
        let tree = try StagedTree.make()
        let drop = try DropFolder()
        defer { drop.remove() }
        let row = folder()
        let pane = pane()
        let host = StubPanelHost()
        pane.host = host
        host.materializeReport = tree.report(for: row, cancelled: true)

        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: row, payload: Data("{}".utf8), delegate: pane
        )
        let url = drop.url.appendingPathComponent("photos")
        pane.filePromiseProvider(provider, writePromiseTo: url) { answered.record($0) }
        await answered.settle()

        #expect(answered.count == 1)
        #expect(answered.error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: tree.holder.path))
        withExtendedLifetime(host) {}
    }

    @Test("a pane with no window controller still answers Finder")
    func hostlessPaneAnswers() {
        let pane = pane()
        let answered = PromiseAnswer()
        let provider = RemoteFilePromiseProvider.promise(
            for: folder(), payload: Data("{}".utf8), delegate: pane
        )
        pane.filePromiseProvider(
            provider, writePromiseTo: URL(fileURLWithPath: "/tmp/dirnex-folder-promise-\(UUID())")
        ) { answered.record($0) }
        #expect(answered.count == 1)
        #expect(answered.error != nil)
    }

    // MARK: - The endings a pane reports

    @Test("a failed staging is answered with the server's error and puts nothing at Finder's path")
    func failedStagingLeavesNothing() throws {
        let drop = try DropFolder()
        defer { drop.remove() }
        let row = folder()
        let report = OperationReport(
            completedItems: 0,
            completedBytes: 0,
            skipped: [],
            failures: [OperationItemFailure(path: row.path, error: .permissionDenied(row.path))],
            wasCancelled: false,
            materialized: []
        )
        let url = drop.url.appendingPathComponent("photos")

        let outcome = RemoteFolderPromise.settle(report, for: row, at: url)

        #expect(outcome.answer as? VFSError == .permissionDenied(row.path))
        // Finder shows nothing for an error answer (probe P1), so the pane has to say it.
        #expect(outcome.failure as? VFSError == .permissionDenied(row.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A job that reports success and names no staged folder must not become an empty folder, or a
    /// `nil` answer with nothing there: Finder would show the drop as done.
    @Test("a job that stages no folder is a failure, not an empty answer")
    func missingStagedTreeIsAFailure() throws {
        let drop = try DropFolder()
        defer { drop.remove() }
        let url = drop.url.appendingPathComponent("photos")

        let outcome = RemoteFolderPromise.settle(.empty, for: folder(), at: url)

        #expect(outcome.answer != nil)
        #expect(outcome.failure != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// P1 found Finder's path empty every time it asked, so anything there arrived while the tree
    /// was coming down, and is not Dirnex's to replace.
    @Test("something put at Finder's path while the tree came down is left alone")
    func occupiedPathIsLeftAlone() throws {
        let tree = try StagedTree.make()
        let drop = try DropFolder()
        defer { drop.remove() }
        let row = folder()
        let url = drop.url.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let theirs = url.appendingPathComponent("theirs.txt")
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)

        let outcome = RemoteFolderPromise.settle(tree.report(for: row), for: row, at: url)

        #expect((outcome.answer as? CocoaError)?.code == .fileWriteFileExists)
        #expect(outcome.failure != nil)
        #expect(try String(contentsOf: theirs, encoding: .utf8) == "theirs")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path) == ["theirs.txt"])
        #expect(!FileManager.default.fileExists(atPath: tree.holder.path))
    }

    // MARK: - Every other app

    /// Slice 3 left the folder out for other apps; since 2026-11-08 it is offered as a zip of itself,
    /// beside the file (`FolderZipHandoffTests` stages and zips one for real). Nothing is read here,
    /// because this backend cannot stage a folder and the board answers for all of its rows or none.
    @Test("over another app a folder beside a file is offered too, to be zipped")
    func handoffOffersTheFolderToo() async throws {
        let file = Fixture.entry("report.pdf")
        let dir = FileEntry(
            path: VFSPath(backend: Fixture.backendID, path: "/photos"),
            name: "photos",
            kind: .directory,
            byteSize: -1,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 8
        )
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.folder-handoff"))
        board.clearContents()
        let routes = pane().dragOutRoutes(for: [file, dir])
        #expect(routes[dir.path] == .downloadFolder)

        let controller = RemoteDragHandoffController(
            board: board,
            entries: [file, dir],
            cache: cache,
            backend: backend,
            holdLimit: .seconds(30),
            surfaceUnderPointer: { .otherApp(processID: 20) },
            showStatus: { _ in },
            onLanded: {},
            onFailure: { _ in },
            offer: DragOutOffer(
                routes: routes, extractions: [:], alreadyHere: { _ in nil }, onLockedRowsLeaving: {}
            )
        )
        controller.pointerMoved()

        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].types.contains(.fileURL))
        #expect(items[1].types.contains(.fileURL))
        #expect(controller.makesZips)
        // Both rows still drop back inside Dirnex on their payloads.
        #expect(PanelPasteboard.payloads(in: board).map(\.path) == [file.path, dir.path])
        controller.dragEnded(mayFinish: false)
        withExtendedLifetime(controller) {}
    }
}

// MARK: - Fixtures

/// What the completion handler was told, and how often (`DragPromiseTests` says why a count).
private final class PromiseAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(any Error)?] = []

    func record(_ error: (any Error)?) { lock.withLock { recorded.append(error) } }
    var count: Int { lock.withLock { recorded.count } }
    var isEmpty: Bool { lock.withLock { recorded.isEmpty } }
    var error: (any Error)? { lock.withLock { recorded.first.flatMap { $0 } } }

    /// Polled with `Task.sleep`: the answer comes off a detached task, which a run-loop spin would
    /// not wait for (docs/NOTES.md ▸ Testing).
    func settle() async {
        let deadline = ContinuousClock.now + .seconds(30)
        while isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}

/// A tree laid out the way `MaterializeRunner` stages a folder: its own holder under the temp root,
/// with the folder's real name inside it.
private struct StagedTree {
    let holder: URL
    let tree: URL

    static func make() throws -> StagedTree {
        let holder = RemoteFileCache.temporaryRoot
            .appendingPathComponent("FolderDragOut-\(UUID().uuidString)", isDirectory: true)
        let tree = holder.appendingPathComponent("photos", isDirectory: true)
        let sub = tree.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "one".write(
            to: tree.appendingPathComponent("one.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "two".write(to: sub.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)
        return StagedTree(holder: holder, tree: tree)
    }

    func report(for row: FileEntry, cancelled: Bool = false) -> OperationReport {
        OperationReport(
            completedItems: cancelled ? 0 : 1,
            completedBytes: 6,
            skipped: [],
            failures: [],
            wasCancelled: cancelled,
            materialized: [
                MaterializedFile(
                    source: row.path,
                    localPath: tree.path,
                    revision: RemoteFileRevision(row),
                    isDirectory: true
                )
            ]
        )
    }
}

/// The folder Finder would have dropped into.
private struct DropFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderDragOut-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
