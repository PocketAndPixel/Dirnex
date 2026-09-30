import Foundation

/// Applying an ``UndoRecord`` — the half of the journal that touches bytes.
///
/// It lives beside the stacks rather than in them because the two are different jobs: `UndoJournal`
/// itself is a pure pair of stacks the app pushes onto and pops from, while everything here reads
/// and writes the filesystem through a `VFSBackend`. Split out when the file reached SwiftLint's
/// 500-line ceiling (docs/NOTES.md ▸ lint ceilings: split by concept, don't shave lines).
///
/// Every primitive collects failures rather than throwing, which is what lets one reoccupied slot
/// leave the rest of a record restored.
extension UndoJournal {
    /// Apply a record's inverse steps against `backend`, collecting per-step failures rather
    /// than aborting on the first — so undoing a five-item move that hits one reoccupied slot
    /// still restores the other four. Pure with respect to the journal; the caller pops the
    /// record and runs this off the main thread.
    public static func revert(_ record: UndoRecord, using backend: any VFSBackend) -> UndoReport {
        var failures: [OperationItemFailure] = []
        for step in record.steps {
            switch step {
            case let .restore(from, to):
                restore(from: from, to: to, using: backend, failures: &failures)
            case let .removeCopy(_, copy):
                removeCopy(at: copy, using: backend, failures: &failures)
            case let .makeCopy(source, copy):
                makeCopy(source: source, copy: copy, using: backend, failures: &failures)
            case let .removeCreatedFolder(path):
                removeCreatedFolder(at: path, using: backend, failures: &failures)
            case let .createFolder(path):
                createFolder(at: path, using: backend, failures: &failures)
            case let .restoreAttributes(path, actsOnLink, apply, _):
                restoreAttributes(apply, at: path, actsOnLink: actsOnLink, failures: &failures)
            case let .restoreAccessControlList(path, actsOnLink, apply, _):
                restoreAccessControlList(
                    apply, at: path, actsOnLink: actsOnLink, failures: &failures
                )
            case let .restoreRemoteAttributes(path, apply, _):
                restoreRemoteAttributes(apply, at: path, using: backend, failures: &failures)
            case let .restoreArchive(archive, snapshot, expected, _):
                restoreArchive(
                    archive, from: snapshot, expecting: expected, failures: &failures
                )
            }
        }
        return UndoReport(failures: failures)
    }

    /// Move `from` back to `to`. Refuses to overwrite a reoccupied `to` (undo must never
    /// destroy data the user created since), and — because a cross-volume move was undone by
    /// copy-then-delete originally — falls back to the copy engine when a plain rename can't
    /// cross the volume boundary.
    private static func restore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if (try? backend.stat(at: to)) != nil {
            failures.append(.init(path: to, error: .alreadyExists(to)))
            return
        }
        do {
            try backend.moveItem(at: from, to: to)
        } catch let VFSError.io(_, code) where code == EXDEV {
            crossVolumeRestore(from: from, to: to, using: backend, failures: &failures)
        } catch let error as VFSError {
            failures.append(.init(path: from, error: error))
        } catch {
            failures.append(.init(path: from, error: .io(path: from, code: 0)))
        }
    }

    /// The cross-volume fallback for `restore`: reverse a copy-then-delete move by moving the
    /// item back through the copy engine.
    ///
    /// It used to require `from.lastComponent == to.lastComponent`, on the stated ground that "a
    /// rename never crosses volumes" — true until a *rename* could answer `EXDEV` too (an S3
    /// prefix, PLAN.md §M21), whose undo lands the item back under a name it does not currently
    /// have. `FileOperation(renaming:to:in:)` carries that name, and for a same-name move it is
    /// `entry.name` — one path, no branch, and no invariant left for the next backend to break.
    private static func crossVolumeRestore(
        from: VFSPath,
        to: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard let parent = to.parent, let entry = try? backend.stat(at: from) else {
            failures.append(.init(path: from, error: .io(path: from, code: EXDEV)))
            return
        }
        let report = CopyEngine.run(
            FileOperation(renaming: entry, to: to.lastComponent, in: parent),
            using: backend,
            conflictPolicy: .fail
        )
        failures.append(contentsOf: report.failures)
    }

    /// Remove a copy the operation created. Already gone → nothing to do (treat as undone).
    private static func removeCopy(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard (try? backend.stat(at: path)) != nil else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Re-create a copy that Undo removed (Redo of a Copy): copy `source` back to exactly
    /// `copy`. Refuses to overwrite a reoccupied `copy` — redo, like undo, never destroys data
    /// the user created since. Runs the tested copy engine with `keepBoth` (so it always lands
    /// somewhere without clobbering), then renames the landing to the exact recorded path, so a
    /// keep-both original ("file copy.txt") is reproduced faithfully rather than as `source`'s
    /// bare name.
    private static func makeCopy(
        source: VFSPath,
        copy: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if (try? backend.stat(at: copy)) != nil {
            failures.append(.init(path: copy, error: .alreadyExists(copy)))
            return
        }
        guard let entry = try? backend.stat(at: source), let parent = copy.parent else {
            failures.append(.init(path: source, error: .notFound(source)))
            return
        }
        let report = CopyEngine.run(
            FileOperation(kind: .copy, sources: [entry], destinationDirectory: parent),
            using: backend,
            conflictPolicy: .keepBoth
        )
        guard report.failures.isEmpty else {
            failures.append(contentsOf: report.failures)
            return
        }
        guard let landed = report.outcomes.first?.landedAt else {
            failures.append(.init(path: source, error: .notFound(source)))
            return
        }
        guard landed != copy else { return }
        do {
            try backend.moveItem(at: landed, to: copy)
        } catch let error as VFSError {
            failures.append(.init(path: copy, error: error))
        } catch {
            failures.append(.init(path: copy, error: .io(path: copy, code: 0)))
        }
    }

    /// Remove a folder New Folder created — but only if it's still an empty directory.
    /// A folder the user has since filled, or one already replaced by something else, is
    /// left untouched: undo protects existing data over completing the reversal.
    private static func removeCreatedFolder(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        guard let entry = try? backend.stat(at: path), entry.kind == .directory else { return }
        guard let children = try? backend.listDirectory(at: path), children.isEmpty else { return }
        do {
            try backend.removeItem(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Re-create a folder Undo removed (Redo of New Folder). An existing directory at `path`
    /// means the redo is already satisfied — a no-op success. Anything *else* now occupying the
    /// path is refused rather than clobbered, mirroring `makeCopy`/`restore`.
    private static func createFolder(
        at path: VFSPath,
        using backend: any VFSBackend,
        failures: inout [OperationItemFailure]
    ) {
        if let existing = try? backend.stat(at: path) {
            if existing.kind != .directory {
                failures.append(.init(path: path, error: .alreadyExists(path)))
            }
            return
        }
        do {
            try backend.createDirectory(at: path)
        } catch let error as VFSError {
            failures.append(.init(path: path, error: error))
        } catch {
            failures.append(.init(path: path, error: .io(path: path, code: 0)))
        }
    }

    /// Exchange an archive with the copy of itself taken before it was rewritten.
    ///
    /// Two refusals, and each is the archive-shaped form of a guard the other steps get from their
    /// paths. **The snapshot has to still be there** — it is evictable by construction
    /// (``ArchiveUndoBudget``), so a record can outlive the bytes it needs, and a swap that
    /// silently did nothing would read as an undo that worked. **And the archive has to still be
    /// the one the rewrite produced**: this is the only step whose destination is always occupied,
    /// by the file it is replacing, so nothing about the paths can tell whether something else has
    /// updated the archive since — only ``ArchiveUndoWitness`` can, and undo protects existing data
    /// over completing the reversal exactly as ``restore(from:to:using:failures:)`` does.
    ///
    /// Local file primitives rather than a backend verb: the swap is an atomic same-directory
    /// rename, which no `VFSBackend` offers, and an archive is a real file on this disk whatever
    /// backend is showing its insides.
    private static func restoreArchive(
        _ archive: VFSPath,
        from snapshot: VFSPath,
        expecting expected: ArchiveUndoWitness,
        failures: inout [OperationItemFailure]
    ) {
        let name = archive.lastComponent
        guard FileManager.default.fileExists(atPath: snapshot.path) else {
            failures.append(.init(
                path: archive,
                error: .unsupported(.archiveUndoCopyUnavailable(archive: name))
            ))
            return
        }
        guard expected.matchesFile(at: archive.path) else {
            failures.append(.init(
                path: archive,
                error: .unsupported(.archiveChangedSinceRewrite(archive: name))
            ))
            return
        }
        do {
            try ArchiveUndoStore.exchange(archiveAt: archive.path, snapshotAt: snapshot.path)
        } catch let error as VFSError {
            failures.append(.init(path: archive, error: error))
        } catch {
            failures.append(.init(path: archive, error: .io(path: archive, code: 0)))
        }
    }
}
