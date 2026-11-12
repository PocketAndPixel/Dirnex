import Foundation

/// Making a new member inside a browsed archive: F7's folder and ⇧F4's new file (taken 2026-11-05
/// from docs/LOCATION-SUPPORT.md, where both were a plain "no" in the archive column).
///
/// The fourth edit a rewrite carries, beside delete, rename and add, and the same shape: the archive
/// is extracted whole into a scratch tree, the edit happens there by real filesystem path, and the
/// tree is repacked. So the pure half is the pair rename already has, which names a member can take
/// and where it lands, plus the one step that makes it. That step lives here rather than in the
/// app's writer because it is the part that decides what "already there" means.
///
/// **A new folder survives the repack in every format the writer produces.** Measured 2026-11-05
/// against bsdtar 3.5.3 (libarchive 3.7.4) before any of this was written: an empty directory and an
/// empty file staged into an extracted zip, 7z, tar and tar.gz each came back as their own entries
/// (`docs/new folder/`, `docs/empty.txt`, 0 bytes), and the encrypted route's walk records every
/// directory whether or not it has children (``ArchiveSourceEnumerator``).
extension ArchiveMutation {
    /// What a create makes.
    public enum Creation: Sendable, Equatable {
        /// An empty directory: F7.
        case folder
        /// An empty regular file: ⇧F4 with a name the archive does not have yet, which the editor
        /// then opens the way F4 opens any member.
        case emptyFile
    }

    /// The inner path a new member named `name` takes inside `innerDirectory` (`/` for the root), or
    /// `nil` for a name no member can have.
    ///
    /// The validation is rename's (``isMemberName(_:)``), for rename's reason: the name is joined
    /// onto a real path in the staged tree, so `..` would climb out of the folder the user is looking
    /// at and `a/b` would land somewhere else in it. The collision is not checked here, because
    /// ``stage(_:at:inWorkingDirectory:)`` is its own guard.
    public static func createdInnerPath(named name: String, inInnerDirectory innerDirectory: String) -> String? {
        guard isMemberName(name) else { return nil }
        let directory = innerDirectory.hasPrefix("/") ? innerDirectory : "/" + innerDirectory
        return (directory as NSString).appendingPathComponent(name)
    }

    /// Make `creation` at `member`'s place in the staged tree at `workingDirectory`.
    ///
    /// **The create is its own collision check**, as the local backend's is: `mkdir(2)` and
    /// `open(2)` with `O_CREAT | O_EXCL` each refuse an occupied name in the same call that would
    /// have made it, so nothing already in the archive is ever replaced or truncated. The tree is
    /// staged on APFS, so a name differing only in case collides too, which is what a local F7 in
    /// the same folder would say. `O_EXCL` also refuses a symlink of that name rather than following
    /// it. A refusal throws ``VFSError/alreadyExists(_:)`` naming `member`, the path in the archive,
    /// so the sentence the app renders is about what the user is looking at and not the scratch copy.
    ///
    /// The member's folder is created first if the staged tree lacks it, as an add does: an archive
    /// lists a folder it has no entry for whenever something is inside it, and extraction makes all
    /// of those, so the only tree without it is an archive changed since it was listed.
    ///
    /// The modes are the local backend's (`0o755`, `0o644`), so a folder made in an archive is stored
    /// as the same folder made on disk would be.
    public static func stage(
        _ creation: Creation,
        at member: VFSPath,
        inWorkingDirectory workingDirectory: String
    ) throws {
        let location = workingLocation(
            ofInnerPath: member.path,
            inWorkingDirectory: workingDirectory
        )
        try FileManager.default.createDirectory(
            atPath: (location as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let cPath = (location as NSString).fileSystemRepresentation
        switch creation {
        case .folder:
            guard mkdir(cPath, 0o755) == 0 else { throw VFSError.fromErrno(errno, path: member) }
        case .emptyFile:
            let descriptor = open(cPath, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            guard descriptor >= 0 else { throw VFSError.fromErrno(errno, path: member) }
            close(descriptor)
        }
    }
}
