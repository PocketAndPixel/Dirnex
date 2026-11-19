import AppKit
import AVFoundation
import DirnexCore
import Testing

@testable import Dirnex

/// Quick View's player (PLAN.md §M42 ▸ Slice 1): a movie or a sound opens paused in an in-process
/// `AVPlayerView` whose controls take the mouse, what AVFoundation refuses still goes to Quick Look,
/// and no way off the file leaves it playing.
@Suite("Quick View player")
@MainActor
struct QuickViewMediaTests {
    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Show `url` and wait for the backend to say it is on screen, which the player does once
    /// AVFoundation has answered whether it opens the file.
    ///
    /// A minute, though the answer takes milliseconds alone: in a full run the main actor's turn after
    /// AVFoundation's answer waited past 10 s (2026-11-19), and a wait *for* something costs nothing
    /// when it is met early (docs/NOTES.md ▸ Testing ▸ Waits, run loops and timing).
    private func show(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        // A backend built on first use is pinned by constraints, and has no frame until a layout.
        view.layoutSubtreeIfNeeded()
    }

    private static let budget = Duration.seconds(60)

    private func movie(in tree: TempDirectory, named name: String = "clip.mp4") async throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try await QuickViewMediaFixtures.writeMovie(to: url)
        return url
    }

    @Test("a movie opens in the player, paused, with Quick Look put away")
    func movieOpensPaused() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        #expect(!media.isHidden)
        #expect(media.hasItem)
        #expect(!media.isPlaying, "nothing plays until it is asked to")
        #expect(view.previewView?.isHidden != false, "Quick Look must not be drawn over or under it")
        guard case .media = view.contentTarget else {
            Issue.record("the ⇧-keys and ⌘P find the player through the content target")
            return
        }
    }

    @Test("a sound opens in the same player")
    func soundOpens() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("tone.wav")
        try QuickViewMediaFixtures.writeSound(to: url)
        let view = surface()
        try await show(url, on: view)
        #expect(view.mediaView?.hasItem == true)
        #expect(view.mediaView?.isHidden == false)
    }

    /// The fallback, and the control for the two above: the same route with a file AVFoundation will
    /// not open ends where every movie ended before this slice.
    @Test("a file AVFoundation refuses goes on to Quick Look")
    func refusedFileFallsBackToQuickLook() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try QuickViewMediaFixtures.matroskaHeader.write(to: url)
        #expect(QuickViewPreviewView.isMedia(url), "the premise: macOS types Matroska as a movie")
        let view = surface()
        try await show(url, on: view)
        #expect(view.mediaView?.isHidden != false)
        #expect(view.mediaView?.hasItem != true)
        #expect(view.previewView?.isHidden == false)
        #expect((view.previewView?.previewItem as? NSURL) == url as NSURL)
    }

    @Test("stepping to another file stops the player and lets the movie go")
    func steppingAwayStops() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        media.togglePlayback()
        #expect(media.isPlaying)
        try await show(try tree.write("notes.txt", contents: "hello\n"), on: view)
        #expect(!media.isPlaying)
        #expect(!media.hasItem)
        #expect(media.isHidden)
    }

    @Test("putting the surface away stops the player")
    func clearingStops() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        media.togglePlayback()
        view.clear()
        #expect(!media.isPlaying)
        #expect(!media.hasItem)
    }

    /// The TypeScript half of the `.ts` rule: the sniff still takes a source file first, and the player
    /// is put away for it rather than left drawn over the text.
    @Test("a TypeScript file named .ts still goes to the text preview")
    func typeScriptStaysText() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        try await show(
            try tree.write("vite.config.ts", contents: "export const beta = 1\n"),
            on: view
        )
        #expect(view.mediaView?.isHidden == true)
        #expect(view.textSurface?.isHidden == false)
    }

    /// The controls are the point of the slice: Quick Look's view swallowed every click, and this one
    /// has to receive them.
    @Test("the player takes the mouse, where Quick Look's view does not")
    func playerTakesTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        // In a window, as the text preview's hit tests are: AVKit lays out its controls for one.
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        let center = NSPoint(x: 400, y: 300)
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        let hit = try #require(view.hitTest(center))
        #expect(hit.isDescendant(of: media), "a click on the player must reach the player")

        let refused = tree.root.appendingPathComponent("film.mkv")
        try QuickViewMediaFixtures.matroskaHeader.write(to: refused)
        try await show(refused, on: view)
        #expect(view.hitTest(center) === view, "over Quick Look the surface keeps swallowing")
    }

    @Test("⇧→ goes to the end and ⇧← back to the start")
    func shiftKeysSeek() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let player = try #require(view.mediaView?.player)
        // An item has no length until it is ready to play, and with none ⇧→ stays where it is by
        // design (`timelineTarget`). Alone it was ready before the key; in a full run (2026-11-19) it
        // was not, and the seek to the end went nowhere.
        try await settleUntil(within: Self.budget) { player.currentItem?.status == .readyToPlay }
        view.scrollContent(.end)
        try await waitForTime(of: player) { $0 > 0.9 }
        view.scrollContent(.top)
        try await waitForTime(of: player) { $0 < 0.05 }
    }

    @Test("⌘P plays and pauses, and nothing about a player zooms")
    func playPauseAndNoZoom() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        media.togglePlayback()
        #expect(media.isPlaying)
        media.togglePlayback()
        #expect(!media.isPlaying)
        #expect(!view.canZoom(.larger) && !view.canZoom(.smaller) && !view.canResetZoom)
        #expect(
            CommandBinding.selector(for: "view.quickViewPlayPause")
                == #selector(BrowserWindowController.toggleQuickViewPlayback(_:))
        )
    }

    private func waitForTime(
        of player: AVPlayer,
        _ isThere: (Double) -> Bool
    ) async throws {
        try await settleUntil(within: Self.budget) { isThere(player.currentTime().seconds) }
        #expect(isThere(player.currentTime().seconds), "at \(player.currentTime().seconds) s")
    }
}
