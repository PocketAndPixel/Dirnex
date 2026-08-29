import AppKit
import DirnexCore

/// Running the Synchronize sheet's comparison, and reporting on it — the scan itself, the summary
/// under the table, and the sentence a failed scan shows.
///
/// Split from ``SyncDirectoriesController`` at M25 Slice 5c along with the layout, when the class
/// body crossed SwiftLint's 250-line ceiling. What is left in the class is the *model*: which rows
/// exist, what action each carries, and which of them the user has checked.
///
/// **The walk and the comparison are two things since M25 Slice 5d**, and the split is what makes
/// comparing by contents affordable at all. The walk happens once: it classifies every row by size,
/// keeps the identical ones, and is the expensive half — a connection per directory over a server,
/// or one exec walk, or a billed request each. Every comparison the picker offers is then *derived*
/// from that one snapshot, which for the two metadata comparisons is instant and reads nothing.
///
/// ``SyncComparison/content`` is the derivation that costs something, and it is three steps rather
/// than one: name the pairs whose bytes decide it (``DirnexCore/DirectorySync/contentCandidates(in:)``),
/// hand them to the panel to be weighed, confirmed and fetched, and re-answer those same rows with
/// the copies that arrived. The panel owns every part a user can see or refuse; what comes back here
/// is a ``DirnexCore/MaterializedPaths``, or `nil` meaning the sheet keeps the comparison it had.
extension SyncDirectoriesController {
    // MARK: - The walk

    /// Walk both trees once, off the main thread, and derive the current comparison from the result.
    ///
    /// Called on load and nowhere else: a comparison change re-derives from what this produced
    /// (``applyComparison(_:)``) rather than reading the folders again, because a comparison is a
    /// question about the same snapshot and asking it again over a server costs another round of
    /// listings for rows nothing has moved.
    func startScan() {
        beginScanning()
        let backend = backend
        let left = leftDir
        let right = rightDir
        let control = scanControl
        Task {
            let outcome = await BlockingWork.run { () -> Result<[SyncEntry], any Error> in
                Result {
                    try DirectorySync.survey(
                        left: left,
                        right: right,
                        leftBackend: backend,
                        rightBackend: backend,
                        isCancelled: { control.isStopped }
                    )
                }
            }
            finishScan(outcome)
        }
    }

    func finishScan(_ outcome: Result<[SyncEntry], any Error>) {
        switch outcome {
        case let .success(entries):
            scanned = entries
            applyComparison(comparison)
        case let .failure(error):
            scanned = []
            finishRows(.failure(error))
        }
    }

    // MARK: - Deriving one comparison from it

    /// Show `requested`, fetching first if it is the one that reads bytes.
    ///
    /// ``SyncDirectoriesController/comparison`` is assigned only once a comparison has actually been
    /// applied, so a content scan the user declines at its download confirmation leaves the sheet
    /// showing what it was showing — the picker is put back rather than the rows being cleared.
    func applyComparison(_ requested: SyncComparison) {
        guard requested == .content else {
            comparison = requested
            render(using: MaterializedPaths())
            return
        }
        let candidates = DirectorySync.contentCandidates(in: scanned)
        let sources = candidates.flatMap { [$0.left, $0.right].compactMap { $0 } }
        guard let onPrepareContents, !sources.isEmpty else {
            // Nothing to fetch: two trees with no same-size pair in them, or a caller that supplies
            // no funnel. Either way the comparator sees whatever the rows already name, which for
            // an all-local pair is every one of them.
            comparison = requested
            render(using: MaterializedPaths())
            return
        }
        beginScanning()
        isDownloadingContents = true
        updateChrome()
        onPrepareContents(sources) { [weak self] paths in
            guard let self else { return }
            isDownloadingContents = false
            guard let paths else {
                // Declined or stopped. The panel has already said whatever needed saying, and the
                // sheet goes back to the comparison it was showing.
                selectComparisonSegment()
                render(using: MaterializedPaths())
                return
            }
            comparison = requested
            selectComparisonSegment()
            render(using: paths)
        }
    }

    /// Re-answer the walk's rows under ``SyncDirectoriesController/comparison``.
    ///
    /// The metadata comparisons read nothing, so they are derived inline — a spinner and a run-loop
    /// hop for arithmetic over rows already in memory would be a flash of "Comparing folders…" for
    /// no work. ``SyncComparison/content`` reads every candidate pair end to end, so it goes off the
    /// main actor and polls the sheet's own Stop while it does.
    private func render(using paths: MaterializedPaths) {
        let left = leftDir.backend
        let right = rightDir.backend
        let comparison = comparison
        guard comparison == .content else {
            finishRows(Result {
                try DirectorySync.recompare(
                    scanned, between: left, and: right, comparison: comparison
                )
            })
            return
        }
        beginScanning()
        let entries = scanned
        let control = scanControl
        Task {
            let outcome = await BlockingWork.run { () -> Result<[SyncEntry], any Error> in
                Result {
                    try DirectorySync.recompare(
                        entries,
                        between: left,
                        and: right,
                        comparison: .content,
                        contentsEqual: { source, other in
                            try Self.compareContents(
                                source, other, through: paths, isCancelled: { control.isStopped }
                            )
                        }
                    )
                }
            }
            finishRows(outcome)
        }
    }

    /// Read one candidate pair through whatever stands for each side on this disk.
    ///
    /// **The comparator still only ever sees real local paths**, which is M24's one structural rule
    /// arriving here: the gesture materialized, this substitutes, and `ByteComparator` is handed two
    /// ordinary files exactly as it was when both sides had to be on this disk. A row with no
    /// stand-in cannot happen — the panel refuses a short set rather than delivering one — and is
    /// refused rather than guessed at, because the alternative is comparing a file against itself.
    /// `nonisolated` because it runs on the `BlockingWork` thread, which is the whole point of it:
    /// reading two files end to end is not the main actor's work.
    private nonisolated static func compareContents(
        _ left: VFSPath,
        _ right: VFSPath,
        through paths: MaterializedPaths,
        isCancelled: () -> Bool
    ) throws -> Bool {
        guard let onDiskLeft = paths.localPath(for: left),
              let onDiskRight = paths.localPath(for: right) else {
            throw VFSError.unsupported(.contentComparisonNeedsLocalFiles)
        }
        return try ByteComparator.localFilesEqual(
            onDiskLeft,
            onDiskRight,
            isCancelled: isCancelled
        )
    }

    // MARK: - Rendering

    private func beginScanning() {
        isScanning = true
        scanError = nil
        spinner.startAnimation(nil)
        updateChrome()
    }

    private func finishRows(_ outcome: Result<[SyncEntry], any Error>) {
        // A stopped scan has no sheet left to report to, and its `CancellationError` is the Stop
        // being honoured rather than a failure to show anybody.
        guard !scanControl.isStopped else { return }
        isScanning = false
        isDownloadingContents = false
        spinner.stopAnimation(nil)
        switch outcome {
        case let .success(entries):
            scanError = nil
            rows = entries.map { entry in
                let action = DirectorySync.defaultAction(for: entry.status, direction: direction)
                return Row(entry: entry, action: action, included: isActionable(action))
            }
        case let .failure(error):
            rows = []
            scanError = describe(error)
        }
        tableView.reloadData()
        updateChrome()
    }

    /// Put the picker back on the comparison that is actually applied — after a declined content
    /// scan, where the segment the user clicked is not the one being shown.
    private func selectComparisonSegment() {
        guard let index = comparisons.firstIndex(of: comparison) else { return }
        comparisonControl.selectedSegment = index
    }

    // MARK: - Chrome

    func updateChrome() {
        directionControl.isEnabled = !isScanning
        comparisonControl.isEnabled = !isScanning
        if isScanning {
            // Two waits that look identical from here and are nothing alike: reading folders, and a
            // transfer that may be minutes of somebody's network. The queue bar carries the bytes
            // and the progress; this says which of the two the sheet is waiting on.
            setStatus(
                isDownloadingContents
                    ? String(
                        localized: "Downloading files to compare…",
                        comment: """
                        Sync status while the files a content comparison has to read are being fetched \
                        from a server or extracted from an archive.
                        """
                    )
                    : String(
                        localized: "Comparing folders…",
                        comment: "Sync status shown while the two folders are being compared."
                    ),
                isError: false
            )
            syncButton.isEnabled = false
            return
        }
        if let scanError {
            setStatus(scanError, isError: true)
            syncButton.isEnabled = false
            return
        }
        if rows.isEmpty {
            setStatus(String(
                localized: "The folders are already in sync.",
                comment: "Sync status: no differences were found."
            ), isError: false)
            syncButton.isEnabled = false
            return
        }
        let checked = rows.filter { $0.included && isActionable($0.action) }
        let copies = checked.count { isCopy($0.action) }
        let deletes = checked.count - copies
        let conflicts = rows.count { $0.action == .conflict }
        var text = String(
            localized: "\(copies) to copy, \(deletes) to delete",
            comment: "Sync status summary; %1$lld files to copy, %2$lld to delete."
        )
        if conflicts > 0 {
            text += " · " + String(
                localized: "\(conflicts) conflicts skipped",
                comment: "Sync status suffix; %lld conflicting items left unchanged. Plural."
            )
        }
        setStatus(text, isError: false)
        syncButton.isEnabled = !checked.isEmpty
    }

    /// Set the footer's line, and hand it its own text as a tooltip.
    ///
    /// The tooltip is belt and braces rather than the design: every sentence this sheet shows is
    /// measured to fit (see the placeholder error below), and the label is the one thing in the
    /// footer allowed to truncate, so a longer one added later shortens itself instead of crushing
    /// the two buttons beside it — which is what an `NSStackView` does when nothing tells it whom to
    /// squeeze (docs/NOTES.md ▸ Localization). What the tooltip buys is that the truncated tail is
    /// still readable rather than gone.
    func setStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// The sentence a failed scan shows.
    ///
    /// Takes any error rather than a ``VFSError``, because a content comparison reads bytes and a
    /// read fails in ways a listing does not.
    private func describe(_ error: any Error) -> String {
        guard let error = error as? VFSError else { return Self.genericScanFailure }
        switch error {
        case let .unsupported(reason) where Self.wouldDownloadPlaceholder(reason):
            // The one refusal a content scan can meet that names something the user can act on, and
            // the reason it is a refusal rather than a download: a tree sweep is not a file anybody
            // pointed at, and the bytes behind an evicted placeholder cannot be weighed before they
            // are asked for — so a scan that read through them would be an unbounded download with
            // no total in front of it (PLAN.md §M25 Slice 5d, docs/NOTES.md ▸ iCloud Drive).
            return String(
                localized: "Some files aren’t downloaded. Compare by size instead.",
                comment: """
                Sync error when a content comparison meets an evicted cloud placeholder, which it \
                refuses to read through rather than downloading a whole tree unasked. It shares the \
                sheet's footer with two buttons, so it is measured: 390 pt at its widest against a \
                432 pt budget, and a longer sentence crushes the buttons rather than truncating.
                """
            )
        case .notFound:
            return String(
                localized: "One of the folders no longer exists.",
                comment: "Sync error: a compared folder was removed."
            )
        case .permissionDenied:
            return String(
                localized: "Permission was denied reading one of the folders.",
                comment: "Sync error: no read permission on a compared folder."
            )
        default:
            return Self.genericScanFailure
        }
    }

    private static var genericScanFailure: String {
        String(
            localized: "The folders couldn’t be compared.",
            comment: "Sync error: the comparison failed for an unspecified reason."
        )
    }

    /// Whether a refusal is the comparator declining to materialize an evicted cloud file — the
    /// same question `PanelViewController+Compare` asks of ⌥F3's pre-flight, over the one error
    /// case that names a file the user can do something about.
    private static func wouldDownloadPlaceholder(_ reason: VFSUnsupportedReason) -> Bool {
        if case .contentComparisonWouldDownload = reason { return true }
        return false
    }
}

/// Stop, for the Synchronize sheet's own scan.
///
/// A plain flag rather than task cancellation, for the reason `BlockingWork` documents: its body
/// runs on a `DispatchQueue` thread, outside any task, so `Task.isCancelled` is always `false`
/// there. `SearchControl` is the same shape one feature over, and carries progress this has no use
/// for — a walk reports per directory and a content pass reports nothing at all, since the count of
/// candidate pairs is known before it starts and the transfer in front of it has the queue bar.
final class SyncScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }
}
