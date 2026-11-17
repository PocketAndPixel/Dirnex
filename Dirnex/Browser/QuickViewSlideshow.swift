import AppKit
import DirnexCore

/// A running Quick View slideshow (PLAN.md §M39 ▸ Slice 16): a countdown that steps the pane's cursor
/// to the next picture, so the file list stays the navigation and the preview follows it as it
/// follows ← / →.
///
/// Owned by the window (`BrowserWindowController+Slideshow`), which builds one on ⇧⌘S and drops it
/// when the show ends. This holds the rules that are about time and about which file: when a
/// countdown starts, what restarts it, and where the next step goes (`Slideshow`, in the core). The
/// page turn and the window's sizes are handed in, so a test drives the whole of it with a pane and a
/// clock of its own.
///
/// **The countdown starts once the picture is on screen**, not when the cursor moved: a camera RAW
/// takes a quarter of a second to decode and a picture on a server has to be fetched first, and
/// either would otherwise spend part of its turn as the previous picture or as a download card.
/// **Any change of file restarts it**, whoever made it: the slideshow's own step, ← / →, a swipe,
/// Space. That is what lets a manual step carry on from where it lands (Oleg's call, 2026-11-15).
@MainActor
final class QuickViewSlideshow {
    /// A countdown that has been started, and the way to call it off.
    struct Countdown {
        let cancel: @MainActor () -> Void
    }

    /// Starts a countdown of the given length that calls back when it ends. `live` sleeps; a test
    /// hands over one it ends itself, so nothing in a test waits on a clock.
    typealias Scheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> Countdown

    /// The pane whose cursor the slideshow walks. Weak, like every other reference to a pane outside
    /// the window that owns it.
    private(set) weak var pane: PanelViewController?
    /// The folder it started in. A pane that has gone anywhere else is no longer showing this
    /// slideshow's pictures, and the window ends it (`isStill(showing:)`).
    let folder: VFSPath

    private let interval: @MainActor () -> Duration
    private let schedule: Scheduler
    /// Turns the page to the displayed row given, always forward.
    private let advance: @MainActor (Int) -> Void
    /// Called when a countdown ends and the pane holds no picture at all any more, so the window can
    /// end a show with nothing left to show.
    var onRunOut: (@MainActor () -> Void)?

    /// The file the current countdown is for, so a delivery of the same file (a background refresh, a
    /// style switch) leaves the countdown running while a different file restarts it.
    private var shownFile: VFSPath?
    private var countdown: Countdown?
    /// Keeps the display awake while the show runs: nobody touches the Mac during a slideshow, and
    /// the screen saver taking over after the idle time would end it for them. `nonisolated(unsafe)`
    /// so the nonisolated `deinit` can end it as a backstop; it is only touched on the main actor.
    private nonisolated(unsafe) var activity: (any NSObjectProtocol)?

    init(
        pane: PanelViewController,
        interval: @escaping @MainActor () -> Duration,
        schedule: @escaping Scheduler = QuickViewSlideshow.live,
        advance: @escaping @MainActor (Int) -> Void
    ) {
        self.pane = pane
        folder = pane.panel.path
        self.interval = interval
        self.schedule = schedule
        self.advance = advance
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Quick View slideshow"
        )
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// The real clock: a task that sleeps for the interval on the main actor.
    static let live: Scheduler = { duration, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            fire()
        }
        return Countdown { task.cancel() }
    }

    /// Whether the display is being kept awake, which is for as long as the show runs.
    var keepsDisplayAwake: Bool { activity != nil }

    /// Whether a countdown is running, rather than the show waiting for a picture to arrive.
    var isCountingDown: Bool { countdown != nil }

    /// Whether `pane`, as it is now, is still showing this slideshow's pictures: the same pane, in
    /// the folder the show started in. Tab to the other pane, or a folder entered or left, ends it.
    func isStill(showing pane: PanelViewController) -> Bool {
        pane === self.pane && pane.panel.path == folder
    }

    /// The surface has been handed the cursor's file, or has finished drawing it. `awaitingContent`
    /// says whether it is still on its way (a picture decoding, a download running), in which case the
    /// countdown waits for the next call.
    func surfaceDidUpdate(awaitingContent: Bool) {
        guard let pane else { return }
        let file = pane.slideshowCursorFile
        if file != shownFile {
            shownFile = file
            cancelCountdown()
        }
        guard countdown == nil, !awaitingContent else { return }
        startCountdown()
    }

    /// Stop counting and let the display sleep again. The window calls this once, as it drops the
    /// show; nothing here runs after it.
    func end() {
        cancelCountdown()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func startCountdown() {
        countdown = schedule(interval()) { [weak self] in self?.countdownDidEnd() }
    }

    private func cancelCountdown() {
        countdown?.cancel()
        countdown = nil
    }

    /// Step to the next picture. A lone picture has no next one but itself, so the show simply
    /// counts again; a pane left with no picture at all ends it.
    private func countdownDidEnd() {
        countdown = nil
        guard let pane, activity != nil else { return }
        let cursor = pane.slideshowCursorIndex
        guard let next = Slideshow.nextSlide(after: cursor ?? -1, in: pane.panel.displayedEntries)
        else {
            onRunOut?()
            return
        }
        guard next != cursor else {
            startCountdown()
            return
        }
        advance(next)
    }
}

extension PanelViewController {
    /// The displayed row the cursor is on, or `nil` on the `..` row, which is no row of the listing.
    var slideshowCursorIndex: Int? {
        cursorOnParentRow ? nil : panel.cursor
    }

    /// The file under the cursor, by identity, or `nil` on the `..` row or in an empty folder.
    var slideshowCursorFile: VFSPath? {
        cursorOnParentRow ? nil : panel.currentEntry?.id
    }

    /// Put the cursor on displayed row `index`, through the table, so the selection mirror, the chrome
    /// and the preview all follow by the one path a key press takes.
    func moveCursor(toDisplayedRow index: Int) {
        tableView.moveCursor(by: parentRowCount + index - tableView.selectedRow)
    }
}
