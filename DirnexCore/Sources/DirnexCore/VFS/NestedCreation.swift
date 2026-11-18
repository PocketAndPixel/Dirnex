import Foundation

/// Making what a ``NestedName`` names through any `VFSBackend`, the folders on the way included:
/// F7 and ⇧F4 on this Mac, a cloud mount or a server (asked 2026-11-18). A browsed archive makes
/// its folders in the staged tree instead (``ArchiveMutation/stage(_:at:inWorkingDirectory:)``).
///
/// **Each folder on the way is read before it is made**, rather than made and the refusal caught.
/// Three reasons, each measured or documented: `mkdir(2)` under a *file* answers `ENOTDIR` naming
/// the path it was given, not the file in the way (probed 2026-11-18), so the sentence would be
/// about the wrong item; S3's `createDirectory` succeeds over a folder that is already there
/// (``VFSBackend/createDirectory(at:)``), so only a read can say whether this create made it; and
/// what F7's undo removes is exactly the folders this create made, never one that was there.
///
/// **A failure takes back the folders it made**, innermost first and each only while empty. A
/// refused F7 records no undo, so a folder left behind by one would have nothing to remove it.
public enum NestedCreation {
    /// Make the folder `name` names inside `directory`, and each folder on the way that is not
    /// there yet. Returns every folder made, outermost first and the named one last: the list F7's
    /// undo record is built from (``UndoRecord/newFolders(_:date:)``).
    ///
    /// The named folder itself is made by `createDirectory`, which refuses one that is already
    /// there, as F7 always has. A folder on the way that is already there is used as it is.
    @discardableResult
    public static func makeFolder(
        _ name: NestedName,
        in directory: VFSPath,
        using backend: any VFSBackend
    ) throws -> [VFSPath] {
        let target = name.target(in: directory)
        return try make(name, in: directory, using: backend) {
            try backend.createDirectory(at: target)
            return [target]
        }
    }

    /// Make the empty file `name` names inside `directory`, and each folder on the way that is not
    /// there yet. Returns the folders made, outermost first.
    ///
    /// The file is made by `createFile`, which never truncates one that is already there (⇧F4 opens
    /// an existing name instead of calling this).
    @discardableResult
    public static func makeFile(
        _ name: NestedName,
        in directory: VFSPath,
        using backend: any VFSBackend
    ) throws -> [VFSPath] {
        let target = name.target(in: directory)
        return try make(name, in: directory, using: backend) {
            try backend.createFile(at: target)
            return []
        }
    }

    /// Make each folder between `directory` and `item` that is not there yet, for a create whose last
    /// step is somebody else's: ⌥F5's archive, which its own writer makes (2026-11-18). Returns the
    /// folders made, outermost first, for ``takeBack(_:using:)`` to remove if that step fails. Makes
    /// nothing when `item` is not below `directory`, or is directly in it.
    @discardableResult
    public static func makeFolders(
        above item: VFSPath,
        below directory: VFSPath,
        using backend: any VFSBackend
    ) throws -> [VFSPath] {
        let chain = item.ancestorsFromRoot.dropLast()
        guard let start = chain.firstIndex(of: directory) else { return [] }
        return try ensureAll(chain[(start + 1)...], using: backend)
    }

    // MARK: - A folder named by a whole path

    /// Where a folder a whole path names stands, read without making anything: there, or missing
    /// below the deepest folder on its way that is there (2026-11-18, for Export's folder field,
    /// which takes a path from a root and asks before it makes anything).
    public enum FolderState: Sendable, Equatable {
        /// The folder is there.
        case present
        /// It is not, and `under` is the deepest folder on its way that is: where making the rest
        /// would start, and whose write permission the rest needs.
        case missing(under: VFSPath)
    }

    /// Read where `folder` stands, from the folder up. Throws ``VFSError/notADirectory(_:)`` naming
    /// the nearest thing on the way that is not a folder, `folder` itself included. The backend root
    /// counts as there without asking, since some backends cannot `stat` their own root.
    public static func state(of folder: VFSPath, using backend: any VFSBackend) throws -> FolderState {
        for path in folder.ancestorsFromRoot.reversed() {
            if !path.isRoot {
                guard let entry = try? backend.stat(at: path) else { continue }
                guard entry.isDirectoryLike else { throw VFSError.notADirectory(path) }
            }
            return path == folder ? .present : .missing(under: path)
        }
        return .present // unreachable: every path's chain ends at its root
    }

    /// Make `folder` and every folder on its way that is not there yet, like `mkdir -p`. Returns the
    /// folders made, outermost first; nothing when `folder` is there. A failure takes back what it
    /// made, as every create here does.
    @discardableResult
    public static func makeFolders(upTo folder: VFSPath, using backend: any VFSBackend) throws -> [
        VFSPath
    ] {
        guard case let .missing(under) = try state(of: folder, using: backend) else { return [] }
        let chain = folder.ancestorsFromRoot
        guard let start = chain.firstIndex(of: under) else { return [] }
        return try ensureAll(chain[(start + 1)...], using: backend)
    }

    // MARK: - The walk

    /// Make sure each of `folders`, outermost first, is a folder, taking back what this call made if
    /// one cannot be. Returns those made.
    private static func ensureAll(
        _ folders: some Sequence<VFSPath>,
        using backend: any VFSBackend
    ) throws -> [VFSPath] {
        var made: [VFSPath] = []
        do {
            for folder in folders where try ensureFolder(folder, using: backend) {
                made.append(folder)
            }
        } catch {
            takeBack(made, using: backend)
            throw error
        }
        return made
    }

    private static func make(
        _ name: NestedName,
        in directory: VFSPath,
        using backend: any VFSBackend,
        leaf: () throws -> [VFSPath]
    ) throws -> [VFSPath] {
        let made = try ensureAll(name.folders(in: directory), using: backend)
        do {
            return try made + leaf()
        } catch {
            takeBack(made, using: backend)
            throw error
        }
    }

    /// Make sure there is a folder at `folder`. `true` when this call made it, `false` when one was
    /// already there; throws ``VFSError/notADirectory(_:)`` naming `folder` when something else is.
    ///
    /// A symlink to a folder counts as a folder (`isDirectoryLike`), as it does for `mkdir -p`. The
    /// `alreadyExists` branch is the race: a folder made by someone else between the read and the
    /// create is used, since the user asked for it to be there and it is.
    private static func ensureFolder(_ folder: VFSPath, using backend: any VFSBackend) throws -> Bool {
        if let entry = try? backend.stat(at: folder) {
            guard entry.isDirectoryLike else { throw VFSError.notADirectory(folder) }
            return false
        }
        do {
            try backend.createDirectory(at: folder)
            return true
        } catch VFSError.alreadyExists {
            guard let entry = try? backend.stat(at: folder), entry.isDirectoryLike else {
                throw VFSError.notADirectory(folder)
            }
            return false
        }
    }

    /// Remove the folders a failed create made, innermost first, each only while it is still empty,
    /// so nothing put there in the meantime is touched. Best effort: the failure being reported is
    /// the create's, and one of these cannot replace it. Public for the pack runners, whose write
    /// comes after ``makeFolders(above:below:using:)`` and can fail or be stopped.
    public static func takeBack(_ made: [VFSPath], using backend: any VFSBackend) {
        for folder in made.reversed() {
            guard let children = try? backend.listDirectory(at: folder), children.isEmpty else {
                continue
            }
            try? backend.removeItem(at: folder)
        }
    }
}
