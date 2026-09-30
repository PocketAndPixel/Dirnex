import DirnexCore

/// What a preview Download and a preview Stop teach the session about how large a file the user is
/// happy to have fetched on a connection (`RemotePreviewAllowance`, 2026-09-12).
///
/// The rules themselves are the core's; what lives here is *which gestures count*. Only a preview
/// counts — the card's Download button, ⌘D, and the ⌘Y / ⌃Q confirmation — because all three run
/// through ``openRemotePreview(alreadyConfirmed:onStarted:onReady:)``. ⏎, F4 and a drag out are
/// about opening a file rather than looking at it, and never reach these.
///
/// Its own file because `PanelViewController+RemoteFile` sits close to SwiftLint's ceiling.
extension PanelViewController {
    /// Whether the placeholder card standing in for the cursor row is offering its Download button.
    ///
    /// The card decides the button's visibility from the same state
    /// (`RemotePreviewPlaceholder.State.offersDownload`), so the Download Preview command and the
    /// button cannot disagree about when there is something to press.
    var offersRemotePreviewDownload: Bool {
        remotePreviewPlaceholder?.state.offersDownload ?? false
    }

    /// Record that the user agreed to bring `entry` down for a preview.
    ///
    /// Called when the transfer actually **starts**, not when it was asked for: a confirmation
    /// answered Cancel starts nothing and therefore agrees to nothing, which is the distinction the
    /// prompt's own `onStart` already draws for the card.
    func recordPreviewAgreement(to entry: FileEntry) {
        host?.remoteFileCache.previewAllowance.recordAgreement(
            toFetch: entry.byteSize,
            on: entry.path.backend,
            previewLimit: AppPreferences.shared.quickViewFetchLimit
        )
    }

    /// Record that the user stopped a preview download of `entry` — the card's Stop, or the
    /// progress sheet's where no card is up.
    ///
    /// Moving the cursor off a row also cancels its fetch, and deliberately does **not** come here:
    /// leaving is what browsing is, and treating it as a refusal would forget the allowance on the
    /// first arrow key.
    func recordPreviewStop(of entry: FileEntry) {
        host?.remoteFileCache.previewAllowance.recordStop(
            ofByteSize: entry.byteSize,
            on: entry.path.backend,
            previewLimit: AppPreferences.shared.quickViewFetchLimit
        )
    }
}
