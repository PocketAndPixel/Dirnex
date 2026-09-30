import AppKit
import DirnexCore

/// The window's share of a remote preview the user has to ask for (2026-09-12): what a change to the
/// Settings limit does to what this session has learned, and the keyboard route to the placeholder
/// card's Download button.
///
/// Its own file because `BrowserWindowController+QuickView` sits at SwiftLint's file ceiling, and
/// because both halves are about the same thing — the moment a preview stops being automatic and
/// somebody has to say yes.
extension BrowserWindowController {
    /// Subscribe to `quickViewFetchLimitDidChange`, so raising the limit resolves the card the user
    /// is *looking at* rather than the one they would see after the next cursor step.
    ///
    /// `updateQuickView()` rather than a re-delivery, because what has changed is the answer to
    /// "may this be fetched" — which is asked by `prepareRemotePreview` on the way in, not by the
    /// surface on the way out. Lowering the limit mid-transfer deliberately does *not* stop it: the
    /// bytes are already being spent, and abandoning them would leave the user with nothing to show
    /// for a download they had already paid for.
    func observeQuickViewFetchLimit() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickViewFetchLimitDidChange),
            name: AppPreferences.quickViewFetchLimitDidChange,
            object: nil
        )
    }

    @objc func quickViewFetchLimitDidChange(_ notification: Notification) {
        // The Settings value is the user's explicit statement and supersedes anything inferred
        // before it, in both directions: lowering it must not leave a ceiling learned under the old
        // value quietly in charge (`RemotePreviewAllowance`).
        remoteFileCache.previewAllowance.removeAll()
        guard isQuickViewEnabled else { return }
        updateQuickView()
    }

    /// View ▸ Download Preview (⌘D): the placeholder card's Download button, from the keyboard.
    ///
    /// The surface refuses first responder so the arrows keep driving the file list, and that left
    /// the mouse as the only way to press the button — while the gesture the card replaces, ⌘Y, opens
    /// Apple's floating panel over Quick View and asks a confirmation first. This runs the card's own
    /// action rather than a second spelling of it, so the key and the button cannot drift apart on
    /// what "download" means: already confirmed (the card names the size), the card redrawn as a
    /// progress bar when it starts, and the session's allowance taught by the same funnel.
    @objc func downloadQuickViewPreview(_ sender: Any?) {
        guard canDownloadQuickViewPreview else { return }
        previewActions(for: focusedPanel).download()
    }

    /// Whether a placeholder card is standing in for the focused pane's cursor row and offering
    /// Download — the one question the menu validator and the action both ask.
    var canDownloadQuickViewPreview: Bool {
        isQuickViewEnabled && focusedPanel.offersRemotePreviewDownload
    }
}
