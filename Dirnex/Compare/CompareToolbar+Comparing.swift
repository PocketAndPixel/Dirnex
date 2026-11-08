import AppKit
import DirnexCore

/// What the toolbar says in words, and what it shows while a comparison takes a while (PLAN.md §M37
/// Slice 3). Split out of the toolbar when Stop took it past the type-body ceiling.
extension CompareToolbar {
    /// Say the comparison is still running, and offer to stop it.
    func showComparing() {
        comparingState = .comparing
        counter.stringValue = String(
            localized: "Comparing…",
            comment: "Compare window: the two files are still being read and compared."
        )
        comparingSpinner.isHidden = false
        comparingSpinner.startAnimation(nil)
        stopButton.title = String(
            localized: "Stop",
            comment: "Compare window button: stops the comparison that is running."
        )
        stopButton.toolTip = "\(stopButton.title) (⌘.)"
        stopButton.isHidden = false
        navigation.setEnabled(false, forSegment: 0)
        navigation.setEnabled(false, forSegment: 1)
    }

    /// Say the comparison was stopped, and offer to run it again.
    func showStopped() {
        comparingState = .stopped
        counter.stringValue = String(
            localized: "Stopped",
            comment: "Compare window: the comparison was stopped before it finished."
        )
        comparingSpinner.stopAnimation(nil)
        comparingSpinner.isHidden = true
        stopButton.title = String(
            localized: "Compare Again",
            comment: "Compare window button: runs the comparison that was stopped."
        )
        stopButton.toolTip = nil
        stopButton.isHidden = false
        navigation.setEnabled(false, forSegment: 0)
        navigation.setEnabled(false, forSegment: 1)
    }

    /// Stop saying either: the counter is the comparison's again.
    func showFinishedComparing() {
        comparingState = .idle
        comparingSpinner.stopAnimation(nil)
        comparingSpinner.isHidden = true
        stopButton.isHidden = true
    }

    /// The spinner and the button beside the counter, hidden until a comparison takes a while.
    func buildComparing() {
        comparingSpinner.style = .spinning
        comparingSpinner.controlSize = .small
        comparingSpinner.isDisplayedWhenStopped = false
        comparingSpinner.isHidden = true
        stopButton.bezelStyle = .push
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stopButton.isHidden = true
        stopButton.target = self
        stopButton.action = #selector(stopOrCompareAgain(_:))
    }

    @objc func stopOrCompareAgain(_ sender: Any?) {
        switch comparingState {
        case .comparing: onStop?()
        case .stopped: onCompareAgain?()
        case .idle: break
        }
    }

    // MARK: - Words

    /// "Change 3 of 12", "12 changes" or "No differences".
    static func counterText(current: Int?, count: Int) -> String {
        guard count > 0 else {
            return String(
                localized: "No differences",
                comment: "Compare window: the two texts have no changed line."
            )
        }
        guard let current else {
            return String(
                localized: "\(count) changes",
                comment: "Compare window: how many changes; %lld is the count."
            )
        }
        return String(
            localized: "Change \(current + 1) of \(count)",
            comment: "Compare window: the change on screen; the first %lld is its position, the second the count."
        )
    }

    /// What the menu's Undo names a copy by: "Undo Copy to Right".
    static func copyTitle(to side: ComparisonPaneText.Side) -> String {
        switch side {
        case .left:
            String(
                localized: "Copy to Left",
                comment: "Compare window button, tooltip and undo name."
            )
        case .right:
            String(
                localized: "Copy to Right",
                comment: "Compare window button, tooltip and undo name."
            )
        }
    }

    static func title(for whitespace: LineDiffOptions.Whitespace) -> String {
        switch whitespace {
        case .compare:
            String(localized: "Compare Whitespace", comment: "Compare window whitespace option.")
        case .ignoreTrailing:
            String(
                localized: "Ignore Whitespace at Line End",
                comment: "Compare window whitespace option."
            )
        case .ignoreChanges:
            String(
                localized: "Ignore Changes in Whitespace",
                comment: "Compare window whitespace option."
            )
        case .ignoreAll:
            String(localized: "Ignore All Whitespace", comment: "Compare window whitespace option.")
        }
    }
}
