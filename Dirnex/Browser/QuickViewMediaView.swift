import AppKit
import AVKit
import DirnexCore

/// Quick View's player for a movie or a sound (PLAN.md §M42 ▸ Slice 1): AVKit's `AVPlayerView` and the
/// one `AVPlayer` it drives, for as long as the surface lives.
///
/// In-process, which is the reason it exists. Quick Look drew these files before, in another process,
/// where the surface has to swallow every click on its behalf (docs/NOTES.md ▸ AppKit), so its play
/// button could be seen and never pressed. This view's controls take the mouse, and the keys reach the
/// player from the file table: ⌘P plays and pauses, and the ⇧-keys move along the timeline
/// (`QuickViewScroll.timelineTarget`).
///
/// Nothing plays until it is asked to, and `stop()` is what every way off the file calls, so a sound
/// never goes on after the cursor or the mode has left it.
@MainActor
final class QuickViewMediaView: NSView {
    let playerView = AVPlayerView()
    let player = AVPlayer()

    init() {
        super.init(frame: .zero)
        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        // Quick View has its own full screen (⌃⌥Q), and a second one from inside the preview would
        // leave the window's mode behind it. Picture in picture and sharing would float the file off
        // a surface that follows the cursor.
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.showsSharingServiceButton = false
        player.actionAtItemEnd = .pause
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether a file is loaded, which is what the keys and ⌘P need to have anything to act on.
    var hasItem: Bool { player.currentItem != nil }

    var isPlaying: Bool { player.rate != 0 }

    /// Put `item` up, paused at its start.
    func show(_ item: AVPlayerItem) {
        player.replaceCurrentItem(with: item)
    }

    /// Pause and let the file go. Called when the cursor leaves it, when Quick View closes, and before
    /// the next file is opened, so no sound outlives the file it belongs to.
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    /// ⌘P. At the end it plays again from the start, as QuickTime Player does, rather than doing
    /// nothing at all.
    func togglePlayback() {
        guard let item = player.currentItem else { return }
        if isPlaying {
            player.pause()
            return
        }
        if item.duration.isNumeric, player.currentTime() >= item.duration {
            player.seek(to: .zero)
        }
        player.play()
    }

    /// One of the ⇧-keys, as a move along the timeline. Exact, so ⇧← lands on the first frame and
    /// two presses of ⇧↓ are twenty seconds rather than two nearby keyframes.
    func seek(_ move: QuickViewScroll) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.isNumeric ? item.duration.seconds : nil
        let target = move.timelineTarget(from: player.currentTime().seconds, duration: duration)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}
