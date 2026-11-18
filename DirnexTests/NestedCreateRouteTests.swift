import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// F7 and ⇧F4 with a path for a name, through the pane (2026-11-18): `folder A/sub folder A` reaches
/// the backend as one create per folder that is not there yet, and `Folder A/test.txt` as the folder
/// and then the file, which is then opened by the file's own route.
///
/// The backend is a server's, for `EditFileRouteTests`' reason: a headless pane has no `PanelHost`,
/// so the remote edit route stops at a fetch it cannot start, where a local file would launch the
/// developer's own editor. Only success paths are driven, since a refusal raises an `NSAlert` and a
/// windowless pane runs it modally (docs/NOTES.md ▸ Testing); the refusals are pinned in the core's
/// `NestedNameTests` and `NestedCreationTests`.
@MainActor
@Suite("A typed path through F7 and ⇧F4")
struct NestedCreateRouteTests {
    private static let directory = VFSPath(backend: Fixture.backendID, path: "/")

    private static func pane(_ backend: any VFSBackend) -> PanelViewController {
        PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
    }

    @Test("F7 makes each folder on the way, outermost first")
    func newFolderMakesTheChain() async {
        let backend = PathRecordingBackend()
        let pane = Self.pane(backend)

        await pane.createFolder(named: "folder A/sub folder A", in: Self.directory)

        #expect(backend.madeFolders == ["/folder A", "/folder A/sub folder A"])
    }

    @Test("F7 uses a folder already on the way rather than making it again")
    func newFolderUsesAnExistingFolder() async {
        let backend = PathRecordingBackend(folders: ["/existing"])
        let pane = Self.pane(backend)

        await pane.createFolder(named: "existing/new", in: Self.directory)

        #expect(backend.madeFolders == ["/existing/new"])
    }

    @Test("⇧F4 makes the folder, then the file, then opens it by the server's route")
    func editFileMakesTheFolderAndTheFile() async {
        let backend = PathRecordingBackend()
        let pane = Self.pane(backend)

        await pane.editFile(named: "Folder A/test.txt", in: Self.directory)

        #expect(backend.madeFolders == ["/Folder A"])
        #expect(backend.madeFiles == ["/Folder A/test.txt"])
        // Not "Opening …": `openInEditor` was not reached with a server path.
        #expect(pane.transientStatusToken == 0)
    }

    /// The sentence under F7's, ⇧F4's and a pack's failure alert. A runner or a stage throws
    /// `notADirectory` naming the file in the way, and the generic "That item isn’t a folder." would
    /// not say which name that is; ⌥F5's live check could not capture its alert, so this pins it.
    /// Checked by name rather than by wording, since the test host may run in another language.
    @Test("a failure names the file in the way, and leaves every other refusal's sentence alone")
    func failureNamesTheFileInTheWay() {
        let pane = Self.pane(PathRecordingBackend())
        let archive = VFSPath(backend: Fixture.backendID, path: "/blocker/x.zip")
        let blocker = VFSPath(backend: Fixture.backendID, path: "/blocker")

        let named = pane.describeCreateFailure(VFSError.notADirectory(blocker), making: archive)
        #expect(named.contains("blocker"))
        #expect(named != pane.describe(VFSError.notADirectory(blocker)))
        for error in [VFSError.notADirectory(archive), .alreadyExists(archive), .notFound(archive)] {
            #expect(pane.describeCreateFailure(error, making: archive) == pane.describe(error))
        }
    }

    @Test("⇧F4 on a file already there in a folder opens it and makes nothing")
    func editFileOpensAnExistingNestedFile() async {
        let backend = PathRecordingBackend(folders: ["/a"], files: ["/a/notes.txt"])
        let pane = Self.pane(backend)

        await pane.editFile(named: "a/notes.txt", in: Self.directory)

        #expect(backend.madeFolders.isEmpty)
        #expect(backend.madeFiles.isEmpty)
        #expect(backend.statted.contains("/a/notes.txt"))
        #expect(pane.transientStatusToken == 0)
    }
}

/// A server's backend holding folders and files by path, which records every folder and file it is
/// asked to make. `createDirectory` and `createFile` refuse a path that is taken, as a server's do.
private final class PathRecordingBackend: VFSBackend, @unchecked Sendable {
    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let lock = NSLock()
    private var folders: Set<String>
    private var files: Set<String>
    private var folderLog: [String] = []
    private var fileLog: [String] = []
    private var statLog: [String] = []

    init(folders: Set<String> = [], files: Set<String> = []) {
        self.folders = folders.union(["/"])
        self.files = files
    }

    var madeFolders: [String] { lock.withLock { folderLog } }
    var madeFiles: [String] { lock.withLock { fileLog } }
    var statted: [String] { lock.withLock { statLog } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        let kind: FileEntry.Kind? = lock.withLock {
            statLog.append(path.path)
            if folders.contains(path.path) { return .directory }
            return files.contains(path.path) ? .file : nil
        }
        guard let kind else { throw VFSError.notFound(path) }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return FileEntry(
            path: path, name: path.lastComponent, kind: kind, byteSize: 0,
            modificationDate: date, creationDate: date, isHidden: false,
            permissions: 0o644, inode: 0
        )
    }

    func createDirectory(at path: VFSPath) throws {
        try lock.withLock {
            guard !folders.contains(path.path), !files.contains(path.path) else {
                throw VFSError.alreadyExists(path)
            }
            folders.insert(path.path)
            folderLog.append(path.path)
        }
    }

    func createFile(at path: VFSPath) throws {
        try lock.withLock {
            guard !folders.contains(path.path), !files.contains(path.path) else {
                throw VFSError.alreadyExists(path)
            }
            files.insert(path.path)
            fileLog.append(path.path)
        }
    }
}
