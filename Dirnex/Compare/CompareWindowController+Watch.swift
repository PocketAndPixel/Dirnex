import AppKit
import DirnexCore

/// What the compare window keeps to watch its two files (PLAN.md §M33 Slice 5), by each file's `id`.
@MainActor
final class CompareFileWatch {
    /// One stream per file.
    var watchers: [UUID: DirectoryWatcher] = [:]
    /// Files being read again now.
    var busy: Set<UUID> = []
    /// Files that changed again while one was being read, or while a save ran.
    var changedMeanwhile: Set<UUID> = []
    /// What a file looked like when the window last left it unread: the user kept the window's
    /// copies over it, or it could not be read as text. That state is not looked at again.
    var passedOver: [UUID: ArchiveUndoWitness] = [:]
}

/// Comparing again when a file changes (PLAN.md §M33 Slice 5).
///
/// Every side the window can save is watched from the moment it opens, so a save in the user's
/// editor shows in the window however the editor got the file: Edit Left or Edit Right, F4 in a
/// pane, or another app. The stream is on the file itself, with file events
/// (`DirectoryWatcher(filePath:)`). Probed 2026-10-25, it fired for a write in place, a rename over
/// the file, a delete and create, `replaceItemAt`, NSDocument's safe save and vim's `:wq`, and not
/// once for a sibling written five times.
///
/// A change is a file that no longer matches the witness its side was read or last saved at, so the
/// window's own save, which moves that witness, is not one. The file is read again off the main
/// thread and its side replaces what it showed. That drops the file's copies from Edit ▸ Undo, whose
/// line ranges name the old lines, and keeps the other file's, which name only its own. A side
/// holding copies not yet saved asks first.
extension CompareWindowController {
    /// Watch every side a save can write. `present` calls this, so a window a test builds watches
    /// nothing until the test asks.
    func startWatchingFiles() {
        for side in Self.sides {
            let source = source(on: side)
            guard let path = source.target?.path, fileWatch.watchers[source.id] == nil else {
                continue
            }
            let id = source.id
            // An editor saves a symlink's target, so that is the path the stream is given.
            let watched = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            fileWatch.watchers[id] = DirectoryWatcher(filePath: watched) { [weak self] in
                // FSEvents delivers on its own queue.
                Task { @MainActor in self?.fileMayHaveChanged(id) }
            }
        }
    }

    func stopWatchingFiles() {
        for watcher in fileWatch.watchers.values {
            watcher.stop()
        }
        fileWatch.watchers = [:]
    }

    /// A watched file's stream fired: read the file again if it no longer looks as the window left
    /// it. While it is being read, or while a save runs, the look waits until that ends.
    func fileMayHaveChanged(_ id: UUID) {
        guard fileWatch.watchers[id] != nil else { return }
        guard !isSaving, !fileWatch.busy.contains(id) else {
            fileWatch.changedMeanwhile.insert(id)
            return
        }
        // A file that is not there has not changed: an editor's atomic save can be caught between
        // taking the old file away and putting the new one in its place.
        guard let side = side(ofFile: id), let target = source(on: side).target,
              let now = ArchiveUndoWitness.current(ofFileAt: target.path),
              now != target.witness, now != fileWatch.passedOver[id] else { return }
        fileWatch.busy.insert(id)
        Task { await readAgain(id, at: target.path, seen: now) }
    }

    /// Look at the files that changed while a save ran.
    func lookAgainAfterSave() {
        let waiting = fileWatch.changedMeanwhile.subtracting(fileWatch.busy)
        fileWatch.changedMeanwhile.subtract(waiting)
        for id in waiting {
            fileMayHaveChanged(id)
        }
    }

    /// Read the file `id` names again and show it, unless the user keeps the copies made on it.
    /// `seen` is what the file looked like when the change was noticed.
    private func readAgain(_ id: UUID, at path: String, seen: ArchiveUndoWitness) async {
        defer {
            fileWatch.busy.remove(id)
            if fileWatch.changedMeanwhile.remove(id) != nil { fileMayHaveChanged(id) }
        }
        guard let side = side(ofFile: id) else { return }
        let source = source(on: side)
        let read = await BlockingWork.run { CompareOpener.reread(source, at: path) }
        // A save that started during the read checks the file itself, and the look waits for it.
        guard !isSaving else {
            fileWatch.changedMeanwhile.insert(id)
            return
        }
        // Swap Sides may have moved the file meanwhile, and a copy may have landed on it.
        guard let side = self.side(ofFile: id) else { return }
        switch read {
        case let .success(reread):
            if unsavedSides.contains(side) {
                guard await askToReadAgain(reread.name) else {
                    fileWatch.passedOver[id] = reread.target?.witness ?? seen
                    return
                }
            }
            replaceFile(id, with: reread)
        case let .failure(failure):
            fileWatch.passedOver[id] = seen
            await reportUnreadableAgain(failure)
        }
    }

    /// Show `reread` in place of the file it was read from, and compare the pair again.
    private func replaceFile(_ id: UUID, with reread: CompareSource) {
        guard let side = side(ofFile: id) else { return }
        // The other file's lines did not move, so its line at the top is the one to keep there.
        let other: ComparisonPaneText.Side = side == .left ? .right : .left
        let kept = topLine(on: other).map { KeptLine(side: other, line: $0) }
        if side == .left { left = reread } else { right = reread }
        edits.removeAllActions(withTarget: reread.undoTarget)
        fileWatch.passedOver[id] = nil
        sidesRevision += 1
        refreshCopyControls()
        compute(options: toolbar.options, keeping: kept) { comparison in
            Self.change(atOrBelow: kept, in: comparison)
        }
        // A local file changed where it lives, so a Synchronize window showing it compares its row
        // again. A copy's change goes nowhere until its write-back lands.
        if reread.writeBack == nil { Self.announceSave(of: reread.origin) }
    }

    /// The change to make current once a file read again has been compared: the first at or below
    /// `kept`'s line, which is at the top, else the last, so a change stays current while any is
    /// left and the copy keys go on working.
    static func change(atOrBelow kept: KeptLine?, in comparison: TextComparison) -> Int? {
        guard !comparison.changeRows.isEmpty else { return nil }
        let row = kept.flatMap { kept in
            comparison.rows.firstIndex { ((kept.side == .left ? $0.left : $0.right) ?? -1) >= kept.line }
        } ?? 0
        return comparison.changeRows.firstIndex { $0.upperBound > row }
            ?? comparison.changeRows.count - 1
    }
}
