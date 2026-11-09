import AppKit
import DirnexCore
import Foundation

@testable import Dirnex

// The fixtures `FolderZipHandoffTests` drags folders with: a real tree, the controller's rig, a
// `bsdtar` listing, two writers that fail or stall the way `ArchivePacker` can, and a server that is
// really a local directory.

/// A folder with a file at the top and one a level down, under a root of its own.
struct FolderZipTree {
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

    static func make() throws -> FolderZipTree {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderZip-\(UUID().uuidString)", isDirectory: true)
        let tree = FolderZipTree(root: root, name: "photos-\(UUID().uuidString.prefix(8))")
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
final class FolderZipRig {
    let board: NSPasteboard
    let cache = RemoteFileCache()
    var surface: RemoteDragHandoff.Surface = .otherApp(processID: 20)
    var shift = false
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
            shiftHeld: { [self] in shift },
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

    /// Take the pointer out of the app it is in and back, which is when Shift counts.
    func reenter(_ controller: RemoteDragHandoffController) {
        let app = surface
        surface = .neutral
        controller.pointerMoved()
        surface = app
        controller.pointerMoved()
    }

    /// What the board's first row answers, holding as an app's read would.
    func readURL() -> URL? {
        board.pasteboardItems?.first?.string(forType: .fileURL).flatMap(URL.init(string:))
            .map(\.standardizedFileURL)
    }
}

enum FolderZipListing {
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
struct FailingZipWriter: PlainPackWriting {
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
final class BlockingZipWriter: PlainPackWriting, @unchecked Sendable {
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
struct MirrorBackend: VFSBackend {
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
