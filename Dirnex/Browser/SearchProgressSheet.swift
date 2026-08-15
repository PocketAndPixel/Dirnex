import AppKit
import DirnexCore

/// The sheet a walking search puts up while it runs: what it has covered so far, and Stop
/// (PLAN.md §M22).
///
/// A remote walk is one round trip per directory — measured at ~0.62 s each — so a search of any
/// real folder runs for a long time with nothing else on screen to say so. Without this, ⌥F7 on a
/// server is indistinguishable from a keystroke the app swallowed.
///
/// **The sheet is deliberately late**, the same shape as `CloudDownloadPrompt`: an archive or a
/// shallow folder answers in a few milliseconds, and flashing a modal on the way is worse than
/// showing nothing. What differs is what the delay is protecting against — there, most calls need no
/// sheet at all because the file is already local; here, every *remote* search will show one, since
/// a single round trip already exceeds the delay (docs/NOTES.md ▸ curl). That is correct rather than
/// unfortunate: the user asked for this and is waiting for it.
@MainActor
final class SearchProgressSheet {
    /// How long a search may run before it is worth putting a sheet up.
    private static let appearanceDelay: Duration = .milliseconds(400)
    /// How often the sheet re-reads what the walk has published. Slow enough to be readable, fast
    /// enough that the counts visibly move.
    private static let pollInterval: Duration = .milliseconds(250)

    private let control: SearchControl
    private let scopeName: String
    private weak var window: NSWindow?

    private var alert: NSAlert?
    /// The live line inside the accessory. Owned directly rather than through `informativeText`,
    /// which an `NSAlert` lays out once when the sheet opens.
    private var statusLabel: NSTextField?
    /// Set before this side takes the sheet down, so its completion handler can tell "the search
    /// finished" from "the user clicked Stop" — both arrive the same way.
    private var isFinished = false

    init(scopeName: String, control: SearchControl, window: NSWindow?) {
        self.scopeName = scopeName
        self.control = control
        self.window = window
    }

    /// Begin the silent wait. The sheet appears by itself if the search is still running when
    /// `appearanceDelay` has passed.
    func start() {
        Task {
            try? await Task.sleep(for: Self.appearanceDelay)
            guard !isFinished, let window else { return }
            present(over: window)
            await poll()
        }
    }

    /// Take the sheet down. Safe to call whether or not it ever appeared, and safe to call twice —
    /// a search that finishes has two natural places to say so, and neither should have to know
    /// whether the other ran.
    func finish() {
        isFinished = true
        guard let alert else { return }
        self.alert = nil
        alert.window.sheetParent?.endSheet(alert.window)
    }

    // MARK: - The sheet

    private func present(over window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "Searching “\(scopeName)”…",
            comment: "Search progress title; %@ is the folder or server being searched."
        )
        alert.addButton(
            withTitle: String(localized: "Stop", comment: "Button that cancels the search.")
        )
        alert.enableEscapeToCancel()

        // Indeterminate, and it cannot honestly be otherwise: finding out how many directories are
        // under the scope *is* the search, so a bar with a percentage would be inventing one. The
        // counts below are the real progress.
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.startAnimation(nil)

        let status = NSTextField(labelWithString: describe(control.progress))
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [bar, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true

        // An `NSAlert` reserves vertical space for its accessory from that view's *frame*, so a
        // pure-Auto-Layout accessory reports a zero frame and the alert draws it over its own text
        // (docs/NOTES.md ▸ AppKit).
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)

        alert.accessoryView = stack
        statusLabel = status
        self.alert = alert

        alert.beginSheetModal(for: window) { [weak self] _ in
            // Stop is the only button, so any response that is not our own dismissal is one.
            guard let self, !isFinished else { return }
            control.stop()
        }
    }

    /// Re-read what the walk has published until it is over.
    private func poll() async {
        while !isFinished {
            try? await Task.sleep(for: Self.pollInterval)
            guard !isFinished, let statusLabel else { return }
            statusLabel.stringValue = describe(control.progress)
        }
    }

    /// Two labelled counts rather than a sentence, and deliberately so: a phrase like "5 folders
    /// searched, 1 found" needs plural agreement on **both** numbers, which is a String Catalog
    /// substitution apiece in fourteen languages for a line that is on screen for seconds. Labelled
    /// numbers carry the same information, scan better in a status line, and have no grammar to get
    /// wrong.
    private func describe(_ progress: SubtreeSearch.Progress) -> String {
        String(
            localized: "Folders searched: \(progress.directoriesListed) · Found: \(progress.hits)",
            comment: """
            Search progress detail. %1$lld is how many folders have been listed so far, \
            %2$lld how many matches were found in them.
            """
        )
    }
}
