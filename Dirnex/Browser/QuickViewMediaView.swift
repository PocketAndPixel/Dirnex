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
///
/// A file AVFoundation will not play gets `card` in the player's place, naming what it is kept in
/// (PLAN.md §M42 ▸ Slice 2), unless it is a Matroska or WebM file the core can read and this Mac can
/// decode, which plays in `matroskaView` instead (Slice 4, `QuickViewMediaView+Matroska`).
@MainActor
final class QuickViewMediaView: NSView {
    let playerView = AVPlayerView()
    let player = AVPlayer()
    /// What a file nothing here can play shows instead of the player. Internal, for the tests.
    let card = QuickViewMediaCard()
    /// Where a Matroska or WebM file plays, and the player playing it. Internal, for the tests.
    let matroskaView = QuickViewMatroskaView()
    var matroska: MatroskaPlayer?

    /// What the file on screen holds, for the header, or `nil` before it has been read.
    private(set) var summary: MediaSummary?
    /// Told whenever what the header says about the player may have moved: a second of playback, a
    /// start or a stop, a seek, a new file. Set by the surface, which redraws its caption.
    var onReadoutChange: (() -> Void)?
    /// The player's periodic report, attached while a file is up and taken off by `stop()`, so a player
    /// with nothing in it reports nothing.
    private var timeObserver: Any?
    /// Set between `prepareForNext()` and the next file going up: the previous file stays on screen,
    /// paused, while the next one opens, but the header already names the next one and must not
    /// carry the previous one's place beside it.
    private var isAwaitingNext = false
    /// How often the readout is asked again while a file plays. It shows whole seconds, and four
    /// asks a second keep its tick within a quarter of one.
    private static let readoutInterval = CMTime(value: 1, timescale: 4)

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
        // Laid out by frame in `layout()`, not pinned, so nothing inside them reaches the pane. AVKit's
        // inline control bar asks for 750 pt at priority 499, above the panes' 250, and a pinned player
        // pushed its pane out to 762 pt. Hidden, it went on holding the pane after Quick View closed,
        // and no divider move could narrow it (2026-11-20, docs/NOTES.md ▸ Views, layout and hit
        // testing). A frame-sized child is a fixed width to the engine, which the 499 cannot move.
        for view in [playerView, matroskaView, card] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
        }
        matroskaView.isHidden = true
        card.isHidden = true
        matroskaView.onSeek = { [weak self] seconds in self?.matroska?.seek(to: seconds) }
    }

    override func layout() {
        super.layout()
        for view in [playerView, matroskaView, card] where view.frame != bounds {
            view.frame = bounds
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Whether a file is loaded, which is what the keys and ⌘P need to have anything to act on.
    var hasItem: Bool { player.currentItem != nil || matroska != nil }

    var isPlaying: Bool { matroska?.isPlaying ?? (player.rate != 0) }

    /// Pause the file on screen and leave it there while the next one opens, as a picture stays until
    /// the next has decoded. Only the sound has to stop at once, and the header's readout goes blank.
    func prepareForNext() {
        player.pause()
        if matroska?.isPlaying == true { matroska?.togglePlayback() }
        isAwaitingNext = true
        onReadoutChange?()
    }

    /// Whether the card is up in the player's place.
    var showsCard: Bool { !card.isHidden }

    /// Put `item` up, paused at its start, with what it holds for the header.
    func show(_ item: AVPlayerItem, summary: MediaSummary) {
        stopMatroska()
        isAwaitingNext = false
        card.isHidden = true
        playerView.isHidden = false
        self.summary = summary
        player.replaceCurrentItem(with: item)
        observeTime()
        onReadoutChange?()
    }

    /// Put `playing` up for a Matroska or WebM file, paused at its start, with what it holds for the
    /// header (PLAN.md §M42 ▸ Slice 4). `player`, AVPlayer, is let go of its item first.
    func show(matroska playing: MatroskaPlayer, summary: MediaSummary, icon: NSImage?) {
        stopMatroska()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        isAwaitingNext = false
        card.isHidden = true
        playerView.isHidden = true
        self.summary = summary
        matroska = playing
        playing.onChange = { [weak self, weak playing] in
            guard let self, let playing else { return }
            matroskaView.update(seconds: playing.currentSeconds, duration: playing.duration)
            onReadoutChange?()
        }
        matroskaView.show(playing, icon: icon)
        matroskaView.isHidden = false
        onReadoutChange?()
    }

    /// Let the Matroska player go, if one is up.
    private func stopMatroska() {
        matroska?.stop()
        matroska = nil
        matroskaView.clear()
        matroskaView.isHidden = true
    }

    /// Put the card up for a file nothing here plays, letting go of whatever the player held.
    func showCard(_ content: QuickViewMediaCard.Content, icon: NSImage?) {
        stop()
        playerView.isHidden = true
        card.show(content, icon: icon)
        card.isHidden = false
    }

    /// Pause and let the file go. Called when the cursor leaves it, when Quick View closes, and before
    /// the next file is opened, so no sound outlives the file it belongs to.
    func stop() {
        stopMatroska()
        isAwaitingNext = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        summary = nil
        card.isHidden = true
        onReadoutChange?()
    }

    /// What the header says about the player: whether it plays, where it is in the file and how long
    /// the file is, and what the file holds. `nil` with no file up, which leaves the header as it is
    /// for every other file.
    var readout: QuickViewMediaReadout? {
        guard hasItem, !isAwaitingNext else { return nil }
        if let matroska { return matroskaReadout(matroska) }
        return QuickViewMediaReadout(
            isPlaying: isPlaying,
            time: MediaTimecode.readout(
                at: player.currentTime().seconds,
                of: summary?.duration
            ),
            facts: summary?.facts ?? ""
        )
    }

    /// Ask for the readout again every `readoutInterval` of playback. AVFoundation also calls the block
    /// when the time jumps and when playback starts or stops, so ⌘P, a seek and the end of the file
    /// reach the header at once rather than at the next tick.
    private func observeTime() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: Self.readoutInterval,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onReadoutChange?() }
        }
    }

    /// ⌘P. At the end it plays again from the start, as QuickTime Player does, rather than doing
    /// nothing at all.
    ///
    /// The header is told at once as well as by the time observer, which hears of the start only once
    /// playback has begun, and under load that can be after the clip has ended.
    func togglePlayback() {
        if let matroska {
            matroska.togglePlayback()
            return
        }
        guard let item = player.currentItem else { return }
        defer { onReadoutChange?() }
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
        if let matroska {
            matroska.seek(move)
            return
        }
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
