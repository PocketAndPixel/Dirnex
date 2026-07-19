import AppKit
import DirnexCore

/// Compare By Contents (PLAN.md §M5) — hand the two panes' cursor files to an external visual diff
/// tool. `ByteComparator` answers *whether* they differ; FileMerge / Kaleidoscope / BBEdit answer
/// *how*. Split out of `PanelViewController+Sync`, which owns the folder-level Synchronize sheet:
/// the two share a launcher but nothing else, and the sync file was near its length budget.
///
/// The pane holds only the AppKit shell — which two files, whether it's worth launching at all, and
/// what to tell the user. Every byte the decision rests on is read by the tested `ByteComparator`.
extension PanelViewController {
    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    /// Compare the two panes' cursor files. Cursor-to-cursor keeps the choice explicit and
    /// predictable — put the two files under the cursors and invoke it.
    @objc func compareByContents(_ sender: Any?) {
        guard let (left, right) = comparableCursorPair() else {
            presentOperationFailure(
                message: "Nothing to compare",
                detail: "Put a file under the cursor in each panel, then compare them."
            )
            return
        }
        launchExternalDiff(comparing: left, with: right)
    }

    /// The two local, regular files to compare, or `nil` when either side isn't a real file on
    /// disk. Comparing a path with itself is refused (nothing to diff).
    ///
    /// **The physical left pane is always the left side**, regardless of which pane is focused —
    /// the same rule `beginSync` follows, and for a stronger reason here: the diff tool labels its
    /// two columns by filename, and comparing `report.log` against `report.log` leaves the pane
    /// each column came from readable only in the path subtitle. Deriving the order from focus
    /// would silently transpose those columns depending on where the user last clicked.
    private func comparableCursorPair() -> (VFSPath, VFSPath)? {
        guard let window = host as? BrowserWindowController,
              let left = Self.localFileUnderCursor(of: window.leftPanel),
              let right = Self.localFileUnderCursor(of: window.rightPanel),
              left != right else { return nil }
        return (left, right)
    }

    private static func localFileUnderCursor(of pane: PanelViewController) -> VFSPath? {
        guard let entry = pane.panel.currentEntry,
              entry.kind == .file,
              entry.path.backend == .local else { return nil }
        return entry.path
    }

    /// Whether Compare By Contents should be enabled: a real file under the cursor in each pane.
    var canCompareByContents: Bool { comparableCursorPair() != nil }

    // MARK: - Launch

    /// Compare two files, pre-flighting the launch off the main thread. Also the entry point the
    /// Synchronize sheet's "Compare with …" row action uses.
    ///
    /// Three outcomes, and only one of them opens anything: identical files say so and stop (a
    /// multi-second GUI launch to be told "0 differences" is the worst payoff the feature has),
    /// files too large to scan ask first, and everything else launches. A pre-flight *failure*
    /// (permission, vanished mid-read) launches anyway — this is an optimization, not a gate, and
    /// the diff tool reports an unreadable file better than a second alert here would.
    func launchExternalDiff(comparing left: VFSPath, with right: VFSPath) {
        guard let tool = ExternalDiffLauncher.preferredTool() else {
            presentDiffFailure(.noToolInstalled)
            return
        }
        showComparisonProgress("Comparing \(left.lastComponent)…")
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                try? ByteComparator.prescan(left, right)
            }.value
            guard let self else { return }
            // `nil` is a pre-flight that threw — fall through to the launch, as documented above.
            switch outcome ?? .different {
            case .identical:
                reportComparisonResult("Files are identical — nothing to compare.")
            case let .tooLargeToScan(largestByteSize):
                confirmOversizedCompare(left, right, tool: tool, byteSize: largestByteSize)
            case .different:
                spawn(tool, comparing: left, with: right)
            }
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
        alert.messageText = "These files are large (\(FileFormatting.byteString(byteSize)))."
        alert.informativeText = "\(tool.displayName) may take a long time to compare them, or "
            + "become unresponsive."
        alert.addButton(withTitle: "Compare Anyway")
        alert.addButton(withTitle: "Cancel")
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

    /// Spawn the tool and say so. The launch is detached and a cold FileMerge takes seconds to draw
    /// its first window, so without this line the app looks like it swallowed the keystroke.
    private func spawn(_ tool: ExternalDiffTool, comparing left: VFSPath, with right: VFSPath) {
        showComparisonProgress("Opening in \(tool.displayName)…")
        ExternalDiffLauncher.compare(left.path, right.path) { [weak self] result in
            guard case let .failure(failure) = result else { return }
            self?.clearTransientStatus()
            self?.presentDiffFailure(failure)
        }
    }

    // MARK: - Reporting

    /// Where a compare's alert belongs: the sheet on top of the window when one is up — the
    /// Synchronize sheet drives compares too — else the window itself. Stacking a second sheet on
    /// a window that already has one queues it behind the first, where nobody sees it.
    private var alertHostWindow: NSWindow? {
        view.window?.attachedSheet ?? view.window
    }

    /// An in-flight note ("Comparing…", "Opening in FileMerge…"): status line only. Never an alert
    /// — a modal the user must dismiss before the real answer arrives is worse than silence, and
    /// a superseding message replaces it a moment later anyway.
    private func showComparisonProgress(_ message: String) {
        showTransientStatus(message)
    }

    /// A final, non-blocking result. Normally the pane's status line; but when a sheet is up it
    /// covers that status line, so the message becomes an alert on the sheet instead — the
    /// alternative is telling the user nothing at all.
    private func reportComparisonResult(_ message: String) {
        guard let sheet = view.window?.attachedSheet else {
            showTransientStatus(message)
            return
        }
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        alert.beginSheetModal(for: sheet, completionHandler: nil)
    }

    private func presentDiffFailure(_ failure: ExternalDiffLauncher.Failure) {
        switch failure {
        case .noToolInstalled:
            presentOperationFailure(
                message: "No comparison tool found",
                detail: "Install FileMerge (part of Xcode), Kaleidoscope, or BBEdit to compare "
                    + "files side by side."
            )
        case let .launchFailed(tool):
            presentOperationFailure(
                message: "Couldn’t open \(tool.displayName)",
                detail: "\(tool.displayName) is installed but couldn’t be launched."
            )
        }
    }
}
