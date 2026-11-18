import Foundation

// MARK: - Record builders

// Building the record a completed operation leaves on the journal: a transfer from the engine's
// per-item outcomes, a New Folder (one folder, or every folder a typed path made), a rename, a batch
// rename, an archive rewrite and a trash. Out of `UndoJournal.swift` since 2026-11-18, when the New
// Folder record for a typed path took that file past SwiftLint's 500-line ceiling (docs/NOTES.md ▸
// Lint ceilings: split by concept).

public extension UndoRecord {
    /// Build the undo record for a completed copy/move from the engine's per-item outcomes
    /// (`OperationReport.outcomes`). Returns `nil` when nothing is reversible — every item
    /// was skipped by the conflict policy, or every landing overwrote an existing file — so
    /// an un-undoable operation simply never enters the journal.
    ///
    /// - A **copy** is undone by removing each fresh copy (`removeCopy`).
    /// - A **move** is undone by moving each item back to its source (`restore`).
    /// - An item that **overwrote** an existing file is counted in `nonReversibleCount`, not
    ///   reversed: deleting the replacement wouldn't bring back the original it clobbered.
    /// - A **checksum** job has nothing to reverse — it reads bytes and, at most, writes one new
    ///   file the user can delete — so it never enters the journal. Handled explicitly rather than
    ///   through a `default`, so the next kind added is a compile error here and gets thought about.
    /// - An **attributes** job has plenty to reverse and none of it is here: it moves nothing, so it
    ///   produces no `outcomes`, and its undo material is the per-item before/after on
    ///   ``OperationReport/attributeApply``, which ``attributeBatchChange(_:date:)`` turns into a
    ///   record. Returning `nil` is therefore right *and* easy to misread — the caller must build
    ///   from the payload, not from here.
    static func transfer(
        kind: FileOperation.Kind,
        outcomes: [OperationItemOutcome],
        date: Date = Date()
    ) -> UndoRecord? {
        let label: UndoActionLabel
        switch kind {
        case .copy: label = .copy
        case .move: label = .move
        // `.materialize` joins the three that produce no `outcomes`, and for the strongest of the
        // four reasons: the others changed something the user cannot see back; this one moved bytes
        // into a temp directory and changed nothing at all.
        //
        // `.writeBack` is the one whose `nil` is a *refusal* rather than a shrug. It really does
        // change something the user would want back — the server's previous copy — and that copy is
        // what the upload destroyed, so there is nothing to put back rather than nowhere to put it.
        // Every write-back confirmation has said so since M21 Slice 10 ("uploading replaces the
        // copy on the server and can't be undone"), which is what makes this the marked
        // non-reversible operation PLAN.md §6 requires rather than a silently dropped one.
        case .checksum, .attributes, .pack, .plainPack, .materialize, .writeBack: return nil
        }
        var steps: [UndoStep] = []
        var nonReversible = 0
        for outcome in outcomes {
            guard let landed = outcome.landedAt else { continue } // skipped: nothing happened
            if outcome.replacedExisting {
                nonReversible += 1
                continue
            }
            if label == .copy {
                steps.append(.removeCopy(source: outcome.source, copy: landed))
            } else {
                steps.append(.restore(from: landed, to: outcome.source))
            }
        }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(
            label: label,
            date: date,
            steps: steps,
            nonReversibleCount: nonReversible
        )
    }

    /// Undo a New Folder by removing the folder — while it's still empty (`removeCreatedFolder`).
    static func newFolder(at path: VFSPath, date: Date = Date()) -> UndoRecord {
        UndoRecord(label: .newFolder, date: date, steps: [.removeCreatedFolder(path)])
    }

    /// Undo a New Folder that made folders on the way too (`Folder A/sub folder A`, 2026-11-18): one
    /// record, so one ⌘Z takes back everything one F7 made. `made` is outermost first, as
    /// ``NestedCreation/makeFolder(_:in:using:)`` returns it, and the steps remove innermost first,
    /// each only while empty — so `Folder A` goes once `sub folder A` has gone, and stays if the
    /// user has put something beside it. Redo (``inverted``) makes them outermost first again.
    /// `nil` when nothing was made.
    static func newFolders(_ made: [VFSPath], date: Date = Date()) -> UndoRecord? {
        guard !made.isEmpty else { return nil }
        return UndoRecord(
            label: .newFolder,
            date: date,
            steps: made.reversed().map(UndoStep.removeCreatedFolder)
        )
    }

    /// Undo an inline rename by moving the new name back to the old one.
    ///
    /// `madeFolders` are the folders an F2 typed as a path made on the way (2026-11-18:
    /// `Archive/2025/report.pdf`), outermost first. They are removed after the item is back,
    /// innermost first and each only while empty, so one ⌘Z undoes the whole gesture; redo makes
    /// them again before moving the item, since ``inverted`` reverses the steps.
    static func rename(
        from old: VFSPath,
        to new: VFSPath,
        madeFolders: [VFSPath] = [],
        date: Date = Date()
    ) -> UndoRecord {
        UndoRecord(
            label: .rename,
            date: date,
            steps: [.restore(from: new, to: old)] + madeFolders.reversed().map(
                UndoStep.removeCreatedFolder
            )
        )
    }

    /// Undo a Multi-Rename batch by moving each renamed item back to its original name — one
    /// record, so a single Cmd+Z reverses the whole batch (PLAN.md §M4 "applies as one undoable
    /// batch"). Returns `nil` when nothing was renamed. Because the tool never applies a rename
    /// whose target equals another still-present name, every original is free at undo time and
    /// `.restore`'s clobber guard never trips on a batch of its own making.
    ///
    /// `items` is in the order the renames were **carried out**, deepest first (``RenameOrder``),
    /// and the steps undo them in reverse (2026-11-05). In a tree batch that renamed `docs/a.txt`
    /// and then `docs`, each pair's paths are the ones that were true when that rename ran, so
    /// `docs` has to come back first for `docs/b.txt` to be where the next step looks for it.
    static func multiRename(
        _ items: [(original: VFSPath, renamed: VFSPath)],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps = items.reversed().map { UndoStep.restore(from: $0.renamed, to: $0.original) }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: .rename, date: date, steps: steps)
    }

    /// Undo an archive rewrite by exchanging the archive with the copy of itself taken before the
    /// rewrite ran. One step, whichever gesture asked for it — deleting members, adding items and
    /// saving an edited member back all produce exactly one new container.
    ///
    /// Built by ``ArchiveUndoSnapshot/record(date:)`` rather than called directly, because half of
    /// it — `expected` — can only be read once the rewrite has landed.
    ///
    /// `renamed` is the member renames the rewrite carried out, in the order it ran them, when it
    /// was a rename (F2 or ⇧F2 inside an archive). The step holds their reversal, since this record
    /// is the undo direction; its inverse turns them forward again for redo.
    static func archiveRewrite(
        archive: VFSPath,
        snapshot: VFSPath,
        expected: ArchiveUndoWitness,
        restored: ArchiveUndoWitness,
        renamed: [PathRename] = [],
        date: Date = Date()
    ) -> UndoRecord {
        UndoRecord(
            label: .changeArchive,
            date: date,
            steps: [.restoreArchive(
                archive: archive,
                snapshot: snapshot,
                expected: expected,
                restored: restored,
                renames: renamed.isEmpty ? nil : PathRename.reversal(of: renamed)
            )]
        )
    }

    /// Undo a Move-to-Trash by restoring each item from the Trash location it landed at back
    /// to where it came from. Returns `nil` if nothing was actually trashed (e.g. the backend
    /// reported no Trash location for any item).
    static func trash(
        _ items: [(original: VFSPath, trashed: VFSPath)],
        date: Date = Date()
    ) -> UndoRecord? {
        let steps = items.map { UndoStep.restore(from: $0.trashed, to: $0.original) }
        guard !steps.isEmpty else { return nil }
        return UndoRecord(label: .moveToTrash, date: date, steps: steps)
    }
}
