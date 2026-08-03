import AppKit
import DirnexCore

/// Compare By Contents (PLAN.md §M5) — hand a pair of files to an external visual diff tool.
/// `ByteComparator` answers *whether* they differ; FileMerge / Kaleidoscope / BBEdit answer
/// *how*. Split out of `PanelViewController+Sync`, which owns the folder-level Synchronize sheet:
/// the two share a launcher but nothing else, and the sync file was near its length budget.
///
/// The pane holds only the AppKit shell — which two files, whether it's worth launching at all, and
/// what to tell the user. Every byte the decision rests on is read by the tested `ByteComparator`.
extension PanelViewController {
    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    /// Compare a pair of files: the two marked in this pane, else the two panes' cursor files.
    @objc func compareByContents(_ sender: Any?) {
        guard let (left, right) = comparablePair() else {
            presentOperationFailure(
                message: String(
                    localized: "Nothing to compare",
                    comment: "Compare failure title when no file is under the cursor."
                ),
                detail: String(
                    localized: """
                    Put a file under the cursor in each panel, or select exactly two files in one \
                    panel, then compare them.
                    """,
                    comment: "Compare failure detail naming both ways to pick the pair."
                )
            )
            return
        }
        launchExternalDiff(comparing: left, with: right)
    }

    /// The two files to compare, or `nil` when there is no usable pair.
    ///
    /// Two gestures, and the marked one wins: **exactly two files marked in the focused pane**
    /// compares those two, and anything else falls back to the cursor file in each pane. Marks over
    /// the cursor is the rule every other file operation here follows (`selectionTargets`), and two
    /// marks name two specific files where the other pane's cursor is usually wherever it was last
    /// left — so preferring the cursor pair would make the marked gesture unreachable, since the
    /// cursors are almost always both on something.
    ///
    /// A marked pair that isn't comparable (a folder, an archive member) is refused rather than
    /// falling back — diffing two unrelated cursor files instead of what the user marked would be
    /// wrong in the quiet direction.
    ///
    /// Internal rather than private so `CompareSelectionTests` can assert the *pair* — which two
    /// files, in which order — rather than only the `Bool` the menu gate exposes.
    func comparablePair() -> (VFSPath, VFSPath)? {
        let marked = selectionTargets()
        guard marked.count == 2 else { return comparableCursorPair() }
        // Display order, so the upper row is the left column — the in-pane reading of the
        // physical-left-pane rule below.
        return Self.comparablePaths(marked[0], marked[1])
    }

    /// The cursor file in the left pane against the cursor file in the right.
    ///
    /// **The physical left pane is always the left side**, regardless of which pane is focused —
    /// the same rule `beginSync` follows, and for a stronger reason here: the diff tool labels its
    /// two columns by filename, and comparing `report.log` against `report.log` leaves the pane
    /// each column came from readable only in the path subtitle. Deriving the order from focus
    /// would silently transpose those columns depending on where the user last clicked.
    private func comparableCursorPair() -> (VFSPath, VFSPath)? {
        guard let window = host as? BrowserWindowController,
              let left = Self.cursorFile(of: window.leftPanel),
              let right = Self.cursorFile(of: window.rightPanel) else { return nil }
        return Self.comparablePaths(left, right)
    }

    /// The entry under a pane's cursor, or `nil` on the synthetic `..` row — which keeps its own
    /// flag rather than a model row, so `currentEntry` there answers with the *first* file in the
    /// listing (the guard every other cursor-driven command already carries).
    static func cursorFile(of pane: PanelViewController) -> FileEntry? {
        pane.cursorOnParentRow ? nil : pane.panel.currentEntry
    }

    /// The pair of paths to hand the diff tool, or `nil` unless both entries are real regular files
    /// on disk and are two *different* files (there is nothing to diff a path against itself).
    private static func comparablePaths(
        _ left: FileEntry,
        _ right: FileEntry
    ) -> (VFSPath, VFSPath)? {
        guard left.kind == .file, right.kind == .file,
              left.path.backend == .local, right.path.backend == .local,
              left.path != right.path else { return nil }
        return (left.path, right.path)
    }

    /// Whether Compare By Contents should be enabled: two real local files, marked here or under
    /// the two panes' cursors.
    var canCompareByContents: Bool { comparablePair() != nil }

    // MARK: - Launch

    /// Compare two files, pre-flighting the launch off the main thread. Also the entry point the
    /// Synchronize sheet's "Compare with …" row action uses.
    ///
    /// Three outcomes, and only one of them opens anything: identical files say so and stop (a
    /// multi-second GUI launch to be told "0 differences" is the worst payoff the feature has),
    /// files too large to scan ask first, and everything else launches. A pre-flight *failure*
    /// (permission, vanished mid-read) launches anyway — this is an optimization, not a gate, and
    /// the diff tool reports an unreadable file better than a second alert here would.
    ///
    /// **One failure is not "launch anyway": the comparator refusing to download a cloud
    /// placeholder.** Falling through there would hand the placeholder to the diff tool, which
    /// blocks *it* on the same materializing read `ByteComparator` declined to make — the identical
    /// beachball, one process over and with nothing on screen saying why. So that one is caught,
    /// the bytes are fetched where the user can see it happening and stop it, and the compare is
    /// re-run. `downloadingPlaceholders` marks that second run, so it can never loop.
    func launchExternalDiff(
        comparing left: VFSPath,
        with right: VFSPath,
        downloadingPlaceholders: Bool = false
    ) {
        guard let tool = ExternalDiffLauncher.preferredTool() else {
            presentDiffFailure(.noToolInstalled)
            return
        }
        showComparisonProgress(
            String(
                localized: "Comparing \(left.lastComponent)…",
                comment: "In-progress status while comparing; %@ is a file name."
            )
        )
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try ByteComparator.prescan(
                    left,
                    right,
                    allowDataless: downloadingPlaceholders
                ) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(.identical):
                reportComparisonResult(
                    String(
                        localized: "Files are identical — nothing to compare.",
                        comment: "Compare result when the two files match byte for byte."
                    )
                )
            case let .success(.tooLargeToScan(largestByteSize)):
                confirmOversizedCompare(left, right, tool: tool, byteSize: largestByteSize)
            case .success(.different):
                spawn(tool, comparing: left, with: right)
            case let .failure(error) where Self.wouldDownloadPlaceholder(error):
                downloadThenCompare(left, with: right)
            case .failure:
                spawn(tool, comparing: left, with: right) // an optimization that failed, not a gate
            }
        }
    }

    /// Whether a pre-flight failure is the comparator declining to materialize an evicted cloud
    /// file — the one failure whose fall-through would cause exactly the block it prevented.
    private static func wouldDownloadPlaceholder(_ error: any Error) -> Bool {
        guard case let .unsupported(reason) = error as? VFSError,
              case .contentComparisonWouldDownload = reason else { return false }
        return true
    }

    /// Fetch both sides, then compare again.
    ///
    /// No extra confirmation: the user put these two files under the cursors and asked what is in
    /// them, which is the same explicit request Enter and F4 already answer by downloading — and by
    /// the time the refusal fires the sizes have matched, so there is no free answer left to give.
    /// What they get is what those two give: a silent start, a sheet if it takes longer than a
    /// moment, and a Stop button that abandons the compare.
    private func downloadThenCompare(_ left: VFSPath, with right: VFSPath) {
        CloudDownloadPrompt.materialize(
            [left, right],
            using: backend,
            over: alertHostWindow
        ) { [weak self] in
            self?.launchExternalDiff(comparing: left, with: right, downloadingPlaceholders: true)
        }
    }

    /// Ask before handing a very large pair to a visual diff tool: past `prescanByteLimit` the tool
    /// is the slow part, and the user is better placed than we are to say whether it's worth it.
    private func confirmOversizedCompare(
        _ left: VFSPath,
        _ right: VFSPath,
        tool: ExternalDiffTool,
        byteSize: Int64
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "These files are large (\(FileFormatting.byteString(byteSize))).",
            comment: "Oversized-compare warning title; %@ is a formatted byte size."
        )
        alert.informativeText = String(
            localized: "\(tool.displayName) may take a long time to compare them, or become unresponsive.",
            comment: "Oversized-compare warning body; %@ is the diff tool name."
        )
        alert.addButton(
            withTitle: String(
                localized: "Compare Anyway",
                comment: "Proceed button on the oversized-compare warning."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.spawn(tool, comparing: left, with: right)
        }
        if let window = alertHostWindow {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// Hand the pair to the tool, fetching either side's bytes first if it hasn't got any.
    ///
    /// This is the choke point that guarantees the *tool* never gets a placeholder, and it has to be
    /// here rather than only on the refusal path: the two outcomes that reach a launch without the
    /// comparator ever having read a byte — `tooLargeToScan`, and a pre-flight that threw for some
    /// other reason — would otherwise walk a dataless file straight into FileMerge. Both sides are
    /// already local on every ordinary compare, so the common case is one `stat` each and no sheet.
    private func spawn(_ tool: ExternalDiffTool, comparing left: VFSPath, with right: VFSPath) {
        CloudDownloadPrompt.materialize(
            [left, right],
            using: backend,
            over: alertHostWindow
        ) { [weak self] in
            self?.launch(tool, comparing: left, with: right)
        }
    }

    /// Launch the tool and say so. The launch is detached and a cold FileMerge takes seconds to draw
    /// its first window, so without this line the app looks like it swallowed the keystroke.
    private func launch(_ tool: ExternalDiffTool, comparing left: VFSPath, with right: VFSPath) {
        showComparisonProgress(
            String(
                localized: "Opening in \(tool.displayName)…",
                comment: "In-progress status while launching the diff tool; %@ is the tool name."
            )
        )
        ExternalDiffLauncher.compare(left.path, right.path) { [weak self] result in
            guard case let .failure(failure) = result else { return }
            self?.clearTransientStatus()
            self?.presentDiffFailure(failure)
        }
    }

    // MARK: - Reporting

    /// Where a compare's alert belongs: whatever surface is in front of the pane when one is up —
    /// the Synchronize dialog drives compares too — else the window itself. Stacking a second sheet
    /// on a window that already has one queues it behind the first, where nobody sees it.
    ///
    /// `NSApp.modalWindow` is the first question because Synchronize is a *window* now
    /// (`presentAsMovableWindow`), not a sheet, so it is no longer this window's `attachedSheet` —
    /// and an alert hung on the browser window while that dialog is app-modal is one the user
    /// cannot click. The `attachedSheet` fallback still covers the `NSAlert`-based confirmations.
    private var alertHostWindow: NSWindow? {
        NSApp.modalWindow ?? view.window?.attachedSheet ?? view.window
    }

    /// An in-flight note ("Comparing…", "Opening in FileMerge…"): status line only. Never an alert
    /// — a modal the user must dismiss before the real answer arrives is worse than silence, and
    /// a superseding message replaces it a moment later anyway.
    private func showComparisonProgress(_ message: String) {
        showTransientStatus(message)
    }

    /// A final, non-blocking result. Normally the pane's status line; but when a dialog is up it
    /// covers — or, as a modal window, outranks — that status line, so the message becomes an alert
    /// on the dialog instead. The alternative is telling the user nothing at all.
    private func reportComparisonResult(_ message: String) {
        guard let sheet = NSApp.modalWindow ?? view.window?.attachedSheet else {
            showTransientStatus(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.beginSheetModal(for: sheet, completionHandler: nil)
    }

    private func presentDiffFailure(_ failure: ExternalDiffLauncher.Failure) {
        switch failure {
        case .noToolInstalled:
            presentOperationFailure(
                message: String(
                    localized: "No comparison tool found",
                    comment: "Compare failure when no diff tool is installed."
                ),
                detail: String(
                    localized: """
                    Install FileMerge (part of Xcode), Kaleidoscope, or BBEdit to compare files side by side.
                    """,
                    comment: "Compare failure detail suggesting diff tools to install."
                )
            )
        case let .launchFailed(tool):
            presentOperationFailure(
                message: String(
                    localized: "Couldn’t open \(tool.displayName)",
                    comment: "Compare failure when the diff tool won't launch; %@ is the tool name."
                ),
                detail: String(
                    localized: "\(tool.displayName) is installed but couldn’t be launched.",
                    comment: "Compare failure detail; %@ is the diff tool name."
                )
            )
        }
    }
}
