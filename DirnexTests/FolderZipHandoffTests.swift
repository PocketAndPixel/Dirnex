import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A folder dragged toward an app other than Finder is handed over as a zip of itself (2026-11-08).
///
/// Gmail answers "Attachment failed" for a folder dropped from Chrome, so once the pointer is over such
/// an app the drag's handoff offers `<folder>.zip`, made by ⌥F5's own `bsdtar` packer, while Finder is
/// offered the folder itself, before a crossing and after one. A drag session cannot be synthesized,
/// so the real board stands in for the session's and the pointer is injected; the crossing back to
/// Finder was measured with a throwaway drag source (`RemoteDragHandoff`). The zips are real, and a
/// server's folder is really staged first, through a backend that mirrors a local directory under a
/// server's id and routes the way the app's `CompositeBackend` does.
@MainActor
@Suite("Folder zip handoff")
struct FolderZipHandoffTests {
    // MARK: - A folder on this disk

    @Test("a folder on this disk drags to Finder by its own URL, before any app was crossed")
    func localFolderStartsAsItsOwnURL() throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        let row = tree.localEntry
        let routes = pane.dragOutRoutes(for: [row])
        #expect(routes[row.path] == .folderURL)
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.folder-zip.start"))
        board.clearContents()
        #expect(board.writeObjects(PanelPasteboard.dragWriters(
            for: [row], routes: routes, promisedTo: pane
        )))
        #expect(PanelPasteboard.fileURLs(in: board).map(\.path) == [tree.folder.path])
    }

    @Test("over another app a folder on this disk is handed over as a zip of itself")
    func localFolderIsZippedForAnotherApp() throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("local")
        let controller = rig.start([tree.localEntry], route: .folderURL, backend: LocalBackend())

        controller.pointerMoved()
        let zip = try #require(rig.readURL())

        #expect(zip.lastPathComponent == "\(tree.name).zip")
        #expect(try Zip.listing(zip) == tree.zipListing)
        // Under the temp root, which is cleared at the next launch, never beside the folder.
        #expect(zip.path.hasPrefix(RemoteFileCache.temporaryRoot.path))
        #expect(!FileManager.default.fileExists(
            atPath: tree.folder.deletingLastPathComponent().appendingPathComponent(
                zip.lastPathComponent
            ).path
        ))
        controller.dragEnded(mayFinish: false)
    }

    /// The probe of 2026-11-08: a board rewritten back to the folder's own URL over Finder dropped the
    /// folder, where the board another app had been given would have dropped the zip.
    @Test("back over Finder the folder is offered as itself, and as a zip again past it")
    func crossingBackGivesFinderTheFolder() throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("local-crossing")
        let controller = rig.start([tree.localEntry], route: .folderURL, backend: LocalBackend())
        controller.pointerMoved()
        let zip = try #require(rig.readURL())

        rig.surface = .finder(processID: 10)
        controller.pointerMoved()
        #expect(rig.readURL()?.path == tree.folder.path)

        rig.surface = .otherApp(processID: 30)
        controller.pointerMoved()
        #expect(rig.readURL() == zip)
        controller.dragEnded(mayFinish: false)
    }

    // MARK: - A folder on a server

    @Test("a server's folder is staged and zipped, and Finder after a crossing gets the tree")
    func serverFolderIsStagedAndZipped() throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("server")
        let controller = rig.start(
            [tree.remoteEntry], route: .downloadFolder, backend: MirrorBackend(mirror: tree.root)
        )

        controller.pointerMoved()
        let zip = try #require(rig.readURL())
        #expect(zip.lastPathComponent == "\(tree.name).zip")
        #expect(try Zip.listing(zip) == tree.zipListing)

        rig.surface = .finder(processID: 10)
        controller.pointerMoved()
        let staged = try #require(rig.readURL())
        #expect(staged.lastPathComponent == tree.name)
        #expect(
            try String(contentsOf: staged.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "b"
        )
        controller.dragEnded(mayFinish: false)
    }

    // MARK: - The drag ending

    /// A drop is read after it lands, an upload for minutes, so what was taken stays until the next
    /// launch clears the temp root. What nobody took goes at once.
    @Test("the drag's end keeps what the drop took and removes the rest")
    func endKeepsWhatWasTaken() throws {
        for (surface, keepsZip, keepsTree) in [
            (RemoteDragHandoff.Surface.otherApp(processID: 20), true, false),
            (.finder(processID: 10), false, true),
            (.neutral, false, false)
        ] {
            let (zip, staged) = try droppedServerFolder(on: surface, operation: .copy)
            #expect(FileManager.default.fileExists(atPath: zip.path) == keepsZip, "\(surface)")
            #expect(FileManager.default.fileExists(atPath: staged.path) == keepsTree, "\(surface)")
            // What the drop kept would wait for the next launch; a test does not leave it there.
            RemoteDragArtifacts.remove(holderOf: zip)
            RemoteDragArtifacts.remove(holderOf: staged)
        }
        let (zip, staged) = try droppedServerFolder(on: .otherApp(processID: 20), operation: [])
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    /// Drag a server folder over another app, cross to Finder so both artifacts are known, and let go
    /// over `surface`. Returns the zip and the staged tree.
    private func droppedServerFolder(
        on surface: RemoteDragHandoff.Surface,
        operation: NSDragOperation
    ) throws -> (URL, URL) {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("end")
        let controller = rig.start(
            [tree.remoteEntry], route: .downloadFolder, backend: MirrorBackend(mirror: tree.root)
        )
        controller.pointerMoved()
        let zip = try #require(rig.readURL())
        rig.surface = .finder(processID: 10)
        controller.pointerMoved()
        let staged = try #require(rig.readURL())
        rig.surface = surface
        controller.dragEnded(mayFinish: false, operation: operation)
        return (zip, staged)
    }

    // MARK: - Failing and stopping

    /// Before folders were handed off, a drag with no file on a server could only fail extracting;
    /// a server's folder alone made that the wrong sentence.
    @Test("a server folder that fails to come down is a copy that failed, not an extraction")
    func failureTitleNamesTheServer() {
        let server = PanelViewController.handoffFailureTitle(for: [Tree.anyPath: .downloadFolder])
        let archive = PanelViewController.handoffFailureTitle(for: [Tree.anyPath: .extract])
        #expect(server == String(localized: "Couldn’t copy this item from the server"))
        #expect(archive == String(localized: "Couldn’t extract from the archive"))
        #expect(PanelViewController.handoffFailureTitle(
            for: [Tree.anyPath: .extract, .local("/tmp/b"): .download]
        ) == server)
    }

    @Test("a zip that cannot be made says so, after the drag, and leaves nothing behind")
    func failedZipIsReported() throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("fail")
        let controller = rig.start(
            [tree.localEntry], route: .folderURL, backend: LocalBackend(), writer: FailingWriter()
        )

        controller.pointerMoved()
        #expect(rig.readURL() == nil)
        #expect(rig.statuses.last == RemoteDragStatus.compressionFailed)
        controller.dragEnded(mayFinish: false)

        let failure = try #require(rig.failures.first as? DragOutZipFailure)
        #expect(failure.folderName == tree.name)
        #expect(rig.failures.count == 1)
        #expect(Zip.left(named: "\(tree.name).zip").isEmpty)
    }

    /// A zip serves nobody after the drag, so it is stopped however small the pane said the transfer
    /// was, and being stopped is nobody's failure.
    @Test("a drag that ends while zipping stops the zip and leaves nothing")
    func endStopsTheZip() async throws {
        let tree = try Tree.make()
        defer { tree.remove() }
        let rig = Rig("stop")
        let writer = BlockingWriter()
        let controller = rig.start(
            [tree.localEntry], route: .folderURL, backend: LocalBackend(), writer: writer
        )

        controller.pointerMoved()
        #expect(controller.makesZips)
        await until { writer.started }
        controller.dragEnded(mayFinish: true)
        await until { writer.wasCancelled }

        #expect(writer.wasCancelled)
        #expect(rig.failures.isEmpty)
        #expect(Zip.left(named: "\(tree.name).zip").isEmpty)
    }
}

// MARK: - Fixtures

/// A folder with a file at the top and one a level down, under a root of its own.
private struct Tree {
    let root: URL
    let name: String

    /// A path for a test that needs a row's key and nothing else.
    static let anyPath = VFSPath(backend: MirrorBackend.remoteID, path: "/a")

    var folder: URL {
        root.appendingPathComponent(name, isDirectory: true)
    }

    /// What `bsdtar -tf` lists for a zip of the folder: the folder as the one top-level entry.
    var zipListing: [String] {
        ["\(name)/", "\(name)/a.txt", "\(name)/sub/", "\(name)/sub/b.txt"]
    }

    var localEntry: FileEntry {
        entry(VFSPath.local(folder.path))
    }

    /// The same folder, as a row of the mirroring server.
    var remoteEntry: FileEntry {
        entry(VFSPath(backend: MirrorBackend.remoteID, path: "/\(name)"))
    }

    private func entry(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: .directory,
            byteSize: -1,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 9
        )
    }

    static func make() throws -> Tree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderZip-\(UUID().uuidString)", isDirectory: true)
        let tree = Tree(root: root, name: "photos-\(UUID().uuidString.prefix(8))")
        let sub = tree.folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "a".write(
            to: tree.folder.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "b".write(to: sub.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return tree
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Everything a test watches about one controller.
@MainActor
private final class Rig {
    let board: NSPasteboard
    let cache = RemoteFileCache()
    var surface: RemoteDragHandoff.Surface = .otherApp(processID: 20)
    var statuses: [String?] = []
    var failures: [any Error] = []

    init(_ name: String) {
        board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.folder-zip.\(name)"))
        board.clearContents()
    }

    func start(
        _ entries: [FileEntry],
        route: DragOutRoute,
        backend: any VFSBackend,
        writer: any PlainPackWriting = ArchivePacker()
    ) -> RemoteDragHandoffController {
        RemoteDragHandoffController(
            board: board,
            entries: entries,
            cache: cache,
            backend: backend,
            holdLimit: .seconds(30),
            surfaceUnderPointer: { [self] in surface },
            showStatus: { [self] in statuses.append($0) },
            onLanded: {},
            onFailure: { [self] in failures.append($0) },
            offer: DragOutOffer(
                routes: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, route) }),
                extractions: [:],
                // As the pane answers (`materializedURL(for:)`): a row on this disk is here already,
                // as itself, which for a folder is exactly what another app must not be handed.
                alreadyHere: { $0.path.backend == .local ? $0.path.localURL : nil },
                onLockedRowsLeaving: {}
            ),
            zipWriter: writer
        )
    }

    /// What the board's first row answers, holding as an app's read would.
    func readURL() -> URL? {
        board.pasteboardItems?.first?.string(forType: .fileURL).flatMap(URL.init(string:))
            .map(\.standardizedFileURL)
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline, !condition() {
        try? await Task.sleep(for: .milliseconds(25))
    }
}

private enum Zip {
    /// The entries of `zip`, as `bsdtar -tf` prints them, sorted.
    static func listing(_ zip: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ["-tf", zip.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").map(String.init).sorted()
    }

    /// Every file called `name` left under the temp root.
    static func left(named name: String) -> [URL] {
        let found = FileManager.default.enumerator(
            at: RemoteFileCache.temporaryRoot, includingPropertiesForKeys: nil
        )
        return (found?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.lastPathComponent == name }
    }
}

/// A writer whose tool always fails, the way `ArchivePacker` reports a `bsdtar` that exited non-zero.
private struct FailingWriter: PlainPackWriting {
    func pack(
        _ request: PlainPackRequest,
        onProgress: @escaping @Sendable (BsdtarProgressSample) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        FileManager.default.createFile(
            atPath: request.archiveOnDiskPath,
            contents: Data("half".utf8)
        )
        throw VFSError.unsupported(.archiveCreateFailed(archive: "x.zip"))
    }
}

/// A writer that runs until it is stopped, as a large folder's `bsdtar` would, and says it was.
private final class BlockingWriter: PlainPackWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var cancelled = false

    var started: Bool { lock.withLock { didStart } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func pack(
        _ request: PlainPackRequest,
        onProgress: @escaping @Sendable (BsdtarProgressSample) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        FileManager.default.createFile(
            atPath: request.archiveOnDiskPath,
            contents: Data("half".utf8)
        )
        lock.withLock { didStart = true }
        let deadline = Date().addingTimeInterval(30)
        while !isCancelled(), Date() < deadline {
            usleep(5000)
        }
        lock.withLock { cancelled = isCancelled() }
        // `ArchivePacker` removes its partial archive before it throws; the holder is the caller's.
        try? FileManager.default.removeItem(atPath: request.archiveOnDiskPath)
        throw CancellationError()
    }
}

/// A server whose files are a local directory, routed the way the app's `CompositeBackend` routes:
/// a path under the server's id reads the mirror, and a local path is this disk. Staging a folder
/// needs both, since it reads from the server and writes here (`MaterializeRunner`).
private struct MirrorBackend: VFSBackend {
    static let remoteID = VFSBackendID("sftp://test@mirror")
    let mirror: URL
    private let local = LocalBackend()

    init(mirror: URL) {
        self.mirror = mirror
    }

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read, .write] }

    func capabilities(for path: VFSPath) -> VFSCapabilities { capabilities }

    private func onDisk(_ path: VFSPath) -> VFSPath {
        path.backend == .local ? path : .local(mirror.path + path.path)
    }

    /// `entry` as the server's row at `serverPath`, or as itself when it was asked for locally.
    private func asServer(_ entry: FileEntry, at serverPath: VFSPath) -> FileEntry {
        guard serverPath.backend != .local else { return entry }
        return FileEntry(
            path: serverPath,
            name: entry.name,
            kind: entry.kind,
            byteSize: entry.byteSize,
            modificationDate: entry.modificationDate,
            creationDate: entry.creationDate,
            isHidden: entry.isHidden,
            permissions: entry.permissions,
            inode: entry.inode
        )
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try local.listDirectory(at: onDisk(path)).map { child in
            asServer(child, at: VFSPath(backend: path.backend, path: path.path + "/" + child.name))
        }
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        try asServer(local.stat(at: onDisk(path)), at: path)
    }

    func createDirectory(at path: VFSPath) throws { try local.createDirectory(at: onDisk(path)) }

    func createFile(at path: VFSPath) throws { try local.createFile(at: onDisk(path)) }

    func removeItem(at path: VFSPath) throws { try local.removeItem(at: onDisk(path)) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try local.moveItem(at: onDisk(source), to: onDisk(destination))
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try local.copyFile(
            at: onDisk(source), to: onDisk(destination), progress: progress,
            isCancelled: isCancelled
        )
    }
}
