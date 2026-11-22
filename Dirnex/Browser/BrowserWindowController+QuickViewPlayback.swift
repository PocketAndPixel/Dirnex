import AppKit

/// View ▸ Play/Pause (⌘P) on a movie or a sound in Quick View (PLAN.md §M42 ▸ Slice 1), View ▸
/// Next Audio Track (⌥⌘P) for a movie with several sounds (▸ Sound tracks), and the movie carried
/// over when Quick View changes size (▸ Changing size).
///
/// The window's rather than a pane's, for the reason every Quick View command is: at full size the
/// preview is a sibling of the panes, so a pane-hosted selector finds no target once somebody clicks
/// into the player. A menu key equivalent rather than a key monitor's, as zoom's are, so the key is
/// discoverable, rebindable and disabled when there is nothing to play.
extension BrowserWindowController {
    @objc func toggleQuickViewPlayback(_ sender: Any?) {
        guard playableQuickViewMedia != nil else { return }
        visibleQuickViewSurface?.toggleMediaPlayback()
    }

    /// View ▸ Next Audio Track (⌥⌘P): the next sound of a movie that has more than one to play
    /// (PLAN.md §M42 ▸ Sound tracks).
    @objc func nextQuickViewAudioTrack(_ sender: Any?) {
        guard playableQuickViewMedia?.canSwitchSound == true else { return }
        visibleQuickViewSurface?.selectNextMediaSound()
    }

    /// Play/Pause is enabled with a file up, and Next Audio Track with more than one sound in it to
    /// play. One case in `validateMenuItem` for both, for its cyclomatic complexity (docs/NOTES.md).
    func validateQuickViewMediaItem(_ menuItem: NSMenuItem) -> Bool {
        guard let media = playableQuickViewMedia else { return false }
        return menuItem.action != #selector(nextQuickViewAudioTrack(_:)) || media.canSwitchSound
    }

    /// The player on the surface the user is looking at, when it holds a file. The one question the
    /// menu item and its action both ask.
    var playableQuickViewMedia: QuickViewMediaView? {
        guard case let .media(view) = visibleQuickViewSurface?.contentTarget else { return nil }
        return view
    }

    /// Move a movie or a sound from `leaving`, the surface the size before showed, to the one the size
    /// now set shows, so it goes on from where it is, playing or paused, rather than opening again at
    /// its start (Oleg, 2026-11-22). Called before the surfaces are reconciled, which puts `leaving`
    /// away and would stop it. Nothing when Quick View is closing.
    func handOffQuickViewMedia(from leaving: QuickViewPreviewView?) {
        guard let leaving, leaving.hasMediaToHandOff else { return }
        let arriving: QuickViewPreviewView? = switch quickViewMode {
        case .off: nil
        case .pane: counterpart(of: focusedPanel).ensureQuickViewPreview()
        case .fullWindow: ensureFullWindowPreview()
        case .fullScreen: ensureFullScreenPreview()
        }
        if let arriving { leaving.handOffMedia(to: arriving) }
    }
}
