import AppKit

/// View ▸ Play/Pause (⌘P) on a movie or a sound in Quick View (PLAN.md §M42 ▸ Slice 1).
///
/// The window's rather than a pane's, for the reason every Quick View command is: at full size the
/// preview is a sibling of the panes, so a pane-hosted selector finds no target once somebody clicks
/// into the player. A menu key equivalent rather than a key monitor's, as zoom's are, so the key is
/// discoverable, rebindable and disabled when there is nothing to play.
extension BrowserWindowController {
    @objc func toggleQuickViewPlayback(_ sender: Any?) {
        playableQuickViewMedia?.togglePlayback()
    }

    /// The player on the surface the user is looking at, when it holds a file. The one question the
    /// menu item and its action both ask.
    var playableQuickViewMedia: QuickViewMediaView? {
        guard case let .media(view) = visibleQuickViewSurface?.contentTarget else { return nil }
        return view
    }
}
