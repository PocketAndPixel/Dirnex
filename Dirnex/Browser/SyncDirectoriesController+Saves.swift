import AppKit
import DirnexCore

/// Comparing one row again after the compare window saved one of its files (PLAN.md §M33 Slice 4).
///
/// Compare Contents… opens the window on a row whose two files differ, and a save there usually
/// makes them agree, or changes which one is newer. Left as it was, the row would go on offering to
/// copy one file over the other, over the edit just saved. So the row's two files are `stat`ed again
/// and the row is answered as a fresh scan would answer it, under the comparison on screen, and
/// leaves the list once the two agree. Every other row, and every choice made in it, stays.
extension SyncDirectoriesController {
    /// Listen for saves from any compare window while the sheet is up.
    func startObservingCompareSaves() {
        compareSaveObserver = NotificationCenter.default.addObserver(
            forName: CompareWindowController.fileSaved,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let origin = CompareWindowController.savedOrigin(in: notification) else { return }
            MainActor.assumeIsolated { self?.compareAgain(rowShowing: origin) }
        }
    }

    func stopObservingCompareSaves() {
        if let compareSaveObserver {
            NotificationCenter.default.removeObserver(compareSaveObserver)
        }
        compareSaveObserver = nil
    }

    /// Compare the row showing `origin` on either side again, if there is one.
    ///
    /// Skipped while a scan is running: its rows replace these when it lands, and the walk reads
    /// the file as it now stands anyway.
    func compareAgain(rowShowing origin: VFSPath) {
        guard !isScanning, let entry = scanned.first(where: {
            $0.left?.path == origin || $0.right?.path == origin
        }) else { return }
        let backend = backend
        Task {
            let restated = await BlockingWork.run {
                // A side that cannot be read keeps the entry the walk had, since there is nothing
                // newer to say about it.
                (
                    entry.left.map { (try? backend.stat(at: $0.path)) ?? $0 },
                    entry.right.map { (try? backend.stat(at: $0.path)) ?? $0 }
                )
            }
            surveyAgain(entry, left: restated.0, right: restated.1)
        }
    }

    /// Put the row's restated files in ``scanned``, classified by size as the walk classifies
    /// everything, then answer it under the comparison on screen.
    private func surveyAgain(_ entry: SyncEntry, left: FileEntry?, right: FileEntry?) {
        let restated = SyncEntry(
            relativePath: entry.relativePath,
            name: entry.name,
            left: left,
            right: right,
            status: entry.status
        )
        guard let surveyed = try? DirectorySync.recompare(
            [restated],
            between: leftDir.backend,
            and: rightDir.backend,
            comparison: .size,
            includingIdentical: true
        ).first, let index = scanned.firstIndex(where: { $0.relativePath == entry.relativePath })
        else { return }
        scanned[index] = surveyed
        guard comparison == .content, let onPrepareContents,
              let candidate = DirectorySync.contentCandidates(in: [surveyed]).first,
              let left = candidate.left, let right = candidate.right else {
            answerAgain(surveyed, using: MaterializedPaths())
            return
        }
        // The pair's bytes, through the funnel the scan fetched them with. A server file the
        // window just saved was uploaded from the copy the cache holds, so nothing moves.
        onPrepareContents([left, right]) { [weak self] paths in
            guard let paths else { return }
            self?.answerAgain(surveyed, using: paths)
        }
    }

    /// Answer the row under the comparison on screen and put it in the list, or take it out.
    ///
    /// Off the main thread, as the scan's own content comparison is, since it can read both files
    /// end to end. Dropped if a scan or another comparison has taken over the rows meanwhile.
    private func answerAgain(_ surveyed: SyncEntry, using paths: MaterializedPaths) {
        let left = leftDir.backend
        let right = rightDir.backend
        let comparison = comparison
        let control = scanControl
        Task {
            let fresh = await BlockingWork.run {
                try? DirectorySync.recompare(
                    [surveyed],
                    between: left,
                    and: right,
                    comparison: comparison,
                    includingIdentical: true,
                    contentsEqual: { source, other in
                        try Self.compareContents(
                            source, other, through: paths, isCancelled: { control.isStopped }
                        )
                    }
                ).first
            }
            guard let fresh, !isScanning, comparison == self.comparison else { return }
            rows = Self.rows(rows, replacing: fresh, direction: direction)
            tableView.reloadData()
            updateChrome()
        }
    }

    /// `rows` with `fresh` answered in them: gone when its two files agree, in its place by path
    /// otherwise. A row whose status did not move keeps the action and the tick the user gave it;
    /// one whose status moved means something else now, so it takes the direction's default.
    static func rows(_ rows: [Row], replacing fresh: SyncEntry, direction: SyncDirection) -> [Row] {
        var rows = rows
        let index = rows.firstIndex { $0.entry.relativePath == fresh.relativePath }
        guard fresh.status != .identical else {
            if let index { rows.remove(at: index) }
            return rows
        }
        if let index, rows[index].entry.status == fresh.status {
            rows[index] = Row(
                entry: fresh,
                action: rows[index].action,
                included: rows[index].included
            )
            return rows
        }
        let action = DirectorySync.defaultAction(for: fresh.status, direction: direction)
        let row = Row(entry: fresh, action: action, included: isActionable(action))
        if let index {
            rows[index] = row
        } else {
            let place = rows.firstIndex { $0.entry.relativePath > fresh.relativePath } ?? rows.endIndex
            rows.insert(row, at: place)
        }
        return rows
    }
}
