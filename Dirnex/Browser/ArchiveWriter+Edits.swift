import DirnexCore
import Foundation

/// The three edits a rewrite carries — delete a member, rename one, add items in — each one a few
/// lines inside the closure `ArchiveWriter.rewrite` calls between the extract and the repack.
///
/// Split from the engine when `ArchiveWriter` reached SwiftLint's `type_body_length` ceiling, and
/// split **by concept rather than by line count** (docs/NOTES.md ▸ Lint ceilings): what the app asks
/// for is a different thing from how a container is safely replaced, and every one of these is the
/// same three-line shape over a scratch tree while the machinery below them is the part with the
/// atomic swap, the two engines and the undo capture in it.
extension ArchiveWriter {
    /// Delete `innerPaths` (VFS inner paths like `/docs/api/x.md`, a directory removing its whole
    /// subtree) from the archive at `archiveOnDiskPath`, rewriting it in place. Throws — leaving the
    /// original untouched — when the archive can't be read, the repack fails, or the swap fails.
    /// Blocks, so call it off-main.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise, so a caller holding
    /// one may pass it speculatively.
    ///
    /// Returns the copy of the archive taken on the way past, for the caller to journal — or `nil`
    /// when the rewrite is not undoable (see ``rewrite(archiveOnDiskPath:passphrase:undo:edit:)``).
    @discardableResult
    static func delete(
        innerPaths: [String],
        fromArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil,
        undo: ArchiveUndoStorage.Request,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveUndoSnapshot? {
        try rewrite(
            archiveOnDiskPath: archiveOnDiskPath, passphrase: passphrase, undo: undo,
            nameEncoding: nameEncoding
        ) { workingDirectory in
            // Remove each target by its exact extracted path. A member that isn't there (already
            // gone, or a stale selection) is not a failure — the rewrite still drops it.
            for innerPath in innerPaths {
                let location = ArchiveMutation.workingLocation(
                    ofInnerPath: innerPath,
                    inWorkingDirectory: workingDirectory
                )
                try? FileManager.default.removeItem(atPath: location)
            }
        }
    }

    /// Rename the member at `innerPath` to `newName`, in the directory it already sits in,
    /// rewriting the archive at `archiveOnDiskPath` in place. Throws — leaving the original
    /// untouched — when the name is not one a member can take, when a member of that name is
    /// already there, or when the archive can't be read, repacked or swapped. Blocks, so call it
    /// off-main.
    ///
    /// It is `delete`'s twin one verb over: the same extract → edit the staged tree → repack →
    /// atomic swap, with a `moveItem` where that one has a `removeItem`. So it inherits the whole
    /// of what makes the rewrite safe — the original is untouched until the swap, and the copy
    /// `undo` captures is what ⌘Z puts back.
    ///
    /// **The move is its own collision guard, which is the one place this differs from the local
    /// rename.** That one has to `stat` the destination first because it ends in `rename(2)`, which
    /// silently overwrites; `FileManager.moveItem` refuses an occupied destination itself and leaves
    /// its bytes alone, *and* still performs a case-only change on case-insensitive APFS — both
    /// measured 2026-09-10. A second check here could only disagree with the move that follows it.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise; `nameEncoding` is
    /// the code page a legacy archive's names have been declared to be in, without which the
    /// extract refuses before anything is altered and the app offers the chooser instead of an
    /// error (``PanelViewController/offerNameEncoding(after:forArchiveAt:)``).
    @discardableResult
    static func rename(
        innerPath: String,
        to newName: String,
        inArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil,
        undo: ArchiveUndoStorage.Request,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveUndoSnapshot? {
        let archiveName = (archiveOnDiskPath as NSString).lastPathComponent
        // Refused before the archive is even opened: a name that would move the member rather than
        // rename it is the caller's mistake, and paying for an extract to discover it would leave
        // the user waiting on a whole rewrite to be told the name was never usable.
        guard let renamedInnerPath = ArchiveMutation.renamedInnerPath(
            ofInnerPath: innerPath, to: newName
        ) else {
            throw VFSError.unsupported(.archiveUpdateFailed(archive: archiveName))
        }
        return try rewrite(
            archiveOnDiskPath: archiveOnDiskPath, passphrase: passphrase, undo: undo,
            nameEncoding: nameEncoding
        ) { workingDirectory in
            let source = ArchiveMutation.workingLocation(
                ofInnerPath: innerPath, inWorkingDirectory: workingDirectory
            )
            let destination = ArchiveMutation.workingLocation(
                ofInnerPath: renamedInnerPath, inWorkingDirectory: workingDirectory
            )
            do {
                try FileManager.default.moveItem(atPath: source, toPath: destination)
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                // Named as the *member's* path rather than the staged copy's, so the sentence the
                // app renders is about the archive the user is looking at.
                throw VFSError.alreadyExists(
                    VFSPath(
                        backend: .archive(forArchiveAt: archiveOnDiskPath),
                        path: renamedInnerPath
                    )
                )
            }
        }
    }

    /// Add the on-disk items at `localPaths` into the archive's inner directory `innerDirectory`
    /// (`/` = the archive root), rewriting the archive at `archiveOnDiskPath` in place. Each item is
    /// copied under its own last path component; a same-named member already there is replaced (the
    /// app confirms that overwrite first). Throws — leaving the original untouched — when the archive
    /// can't be read, a copy fails, the repack fails, or the swap fails. Blocks and does file copies,
    /// so call it off-main.
    ///
    /// `passphrase` is required for an encrypted archive and ignored otherwise. This is also the
    /// primitive behind editing a member in place: writing one edited file back is an add of that
    /// file into the directory it came from, replacing the member of the same name.
    @discardableResult
    static func add(
        localPaths: [String],
        toInnerDirectory innerDirectory: String,
        ofArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil,
        undo: ArchiveUndoStorage.Request,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveUndoSnapshot? {
        try add(
            localPaths.map {
                ArchiveMutation.Addition(localPath: $0, innerDirectory: innerDirectory)
            },
            ofArchiveAt: archiveOnDiskPath,
            passphrase: passphrase,
            undo: undo,
            nameEncoding: nameEncoding
        )
    }

    /// Add items that land in **different inner directories**, in one rewrite
    /// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
    ///
    /// The general form, and the single-directory spelling above is now one call into it. The
    /// reason it exists is that a rewrite is per **archive**, not per directory: extracting and
    /// repacking the container is the whole cost, so N edited members saved together belong in one
    /// pass whatever folders they came from — where before, a script that rewrote forty members
    /// repacked the archive forty times, each pass extracting and re-compressing everything the
    /// previous one had just written.
    ///
    /// Each directory is created once rather than per item, which matters for the same reason: the
    /// grouping is what makes this a single pass and not a loop that happens to share a scratch
    /// tree.
    @discardableResult
    static func add(
        _ additions: [ArchiveMutation.Addition],
        ofArchiveAt archiveOnDiskPath: String,
        passphrase: ArchivePassphrase? = nil,
        undo: ArchiveUndoStorage.Request,
        nameEncoding: ArchiveNameEncoding? = nil
    ) throws -> ArchiveUndoSnapshot? {
        let name = (archiveOnDiskPath as NSString).lastPathComponent
        return try rewrite(
            archiveOnDiskPath: archiveOnDiskPath, passphrase: passphrase, undo: undo,
            nameEncoding: nameEncoding
        ) { workingDirectory in
            var prepared: Set<String> = []
            for addition in additions {
                // The destination directory exists already when adding into a browsed folder, but
                // make sure — the archive could have been emptied, or the add could target a fresh
                // path. Once per directory, not once per item.
                let destinationDirectory = ArchiveMutation.additionDirectory(
                    forInnerDirectory: addition.innerDirectory,
                    inWorkingDirectory: workingDirectory
                )
                if prepared.insert(destinationDirectory).inserted {
                    try FileManager.default.createDirectory(
                        atPath: destinationDirectory,
                        withIntermediateDirectories: true
                    )
                }
                let sourceURL = URL(fileURLWithPath: addition.localPath)
                let destinationURL = URL(fileURLWithPath: destinationDirectory)
                    .appendingPathComponent(sourceURL.lastPathComponent)
                // Replace a same-named member (the overwrite was confirmed) — `copyItem` would
                // otherwise fail if the destination already exists.
                try? FileManager.default.removeItem(at: destinationURL)
                do {
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                } catch {
                    throw VFSError.unsupported(
                        .archiveAddFailed(item: sourceURL.lastPathComponent, archive: name)
                    )
                }
            }
        }
    }
}
