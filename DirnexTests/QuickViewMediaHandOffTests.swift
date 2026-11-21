import AppKit
import AVFoundation
import Testing

@testable import Dirnex

/// A movie goes on from where it is when Quick View changes size, playing or paused, rather than
/// opening again at its start (asked 2026-11-22). The window hands the player itself from the surface
/// it is leaving to the one it is opening (`handOffMedia`), then puts the first away and asks the
/// second to show the same file, which these tests do in that order.
///
/// The surface a movie arrives on is given the other answer to the autoplay setting from the one it
/// left, so what it does can only be the hand-off. Every fixture is silent.
@Suite("Quick View ▸ a movie carried from one size to the next")
@MainActor
struct QuickViewMediaHandOffTests {
    private func surface(
        autoplay: Bool,
        header: QuickViewPreviewView.Header = .pinned
    ) -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: header,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        view.autoplaysMedia = { autoplay }
        return view
    }

    /// Show `url` with a caption naming it, and wait until the player has it up. A `.ts` reaches the
    /// player only after the text backend has read it and found it binary, which sets no loading flag,
    /// so the wait is on the player itself.
    private func open(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { view.isPlayerShowing(url) }
        view.layoutSubtreeIfNeeded()
    }

    /// What the window does on a change of size, in its order: hand over, put the old surface away,
    /// show the file on the new one.
    private func move(
        _ url: URL,
        from leaving: QuickViewPreviewView,
        to arriving: QuickViewPreviewView
    ) {
        leaving.handOffMedia(to: arriving)
        leaving.clear()
        arriving.show(url, style: .default)
        arriving.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
    }

    /// A minute, for the reason `QuickViewMediaTests.show` gives.
    private static let budget = Duration.seconds(60)

    /// A minute long, so it is still playing when a slow full run gets round to looking.
    private func movie(in tree: TempDirectory, named name: String = "clip.mp4") async throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try await QuickViewMediaFixtures.writeMovie(to: url, seconds: 60)
        return url
    }

    @Test("a playing movie goes on playing at the next size, from where it was")
    func playingMovieGoesOn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await movie(in: tree)
        let pane = surface(autoplay: true)
        try await open(url, on: pane)
        let media = try #require(pane.mediaView)
        let item = try #require(media.player.currentItem)
        try await settleUntil(within: Self.budget) { media.player.currentTime().seconds > 0.5 }
        let reached = media.player.currentTime().seconds

        let full = surface(autoplay: false, header: .floating)
        move(url, from: pane, to: full)

        #expect(full.mediaView === media)
        #expect(pane.mediaView == nil, "the surface put away keeps nothing that could play")
        #expect(media.superview === full.content)
        #expect(media.player.currentItem === item, "the same item, not the file opened again")
        #expect(media.isPlaying)
        #expect(
            media.player.currentTime().seconds >= reached,
            "at \(media.player.currentTime().seconds) s"
        )
        #expect(!full.flipGate.isLoading)
        guard case .media = full.contentTarget else {
            Issue.record("⌘P and the ⇧-keys find the player on the new surface")
            return
        }
        #expect(full.headerView?.caption?.media?.isPlaying == true, "the new header reads ▶")
        full.headerView?.onTogglePlayback?()
        #expect(!media.isPlaying, "the new header's button drives it")
        #expect(
            full.headerView?.caption?.media?.isPlaying == false,
            "and the new header hears of it"
        )
    }

    @Test("a paused movie stays paused at its place, whatever the next size's setting says")
    func pausedMovieStaysPaused() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await movie(in: tree)
        let pane = surface(autoplay: false)
        try await open(url, on: pane)
        let media = try #require(pane.mediaView)
        let item = try #require(media.player.currentItem)
        // A seek before the item is ready has nothing to go to (docs/NOTES.md ▸ Previews).
        try await settleUntil(within: Self.budget) { item.status == .readyToPlay }
        let target = CMTime(seconds: 12.5, preferredTimescale: 600)
        await media.player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)

        let full = surface(autoplay: true, header: .floating)
        move(url, from: pane, to: full)

        #expect(full.mediaView === media)
        #expect(media.player.currentItem === item)
        #expect(!media.isPlaying, "autoplay is for a file opening, and this one is not")
        #expect(
            abs(media.player.currentTime().seconds - 12.5) < 0.05,
            "at \(media.player.currentTime().seconds) s"
        )
        #expect(full.headerView?.caption?.media?.time.hasPrefix("0:12") == true)
    }

    /// The display layer and the synchronizer belong to the player, not to the surface, so they move
    /// with the view: the picture stays in the view that moved, and the clock runs on.
    @Test("the core's player goes on too, with its picture")
    func corePlayerGoesOn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try await MatroskaFixtures.writeMovie(to: url, seconds: 60)
        let pane = surface(autoplay: true)
        try await open(url, on: pane)
        let media = try #require(pane.mediaView)
        let player = try #require(media.sampleBufferPlayer, "the core's player, not the card")
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.5 }
        let reached = player.currentSeconds

        let full = surface(autoplay: false, header: .floating)
        move(url, from: pane, to: full)

        #expect(full.mediaView?.sampleBufferPlayer === player)
        #expect(media.isPlaying)
        #expect(player.currentSeconds >= reached, "at \(player.currentSeconds) s")
        #expect(player.displayLayer?.superlayer === media.sampleBufferView.pictureView.layer)
        try await settleUntil(within: Self.budget) { player.currentSeconds > reached + 0.5 }
        #expect(player.audioError == nil)
    }

    /// The TypeScript sniff takes every `.ts` and `.mts` first and stands the player down for it
    /// (`standDownMedia(unlessShowing:)`), so a camera's clip would start again from the text backend
    /// unless the surface sent a file the player has up straight back to it. The text surface never
    /// being built is what tells the two routes apart: the long way round also ends in the player.
    ///
    /// The fixture is Matroska named `.ts`, which takes the whole `.ts` route: the sniff, the read that
    /// finds it binary, the player. AVFoundation can write no transport stream, and which player ends
    /// up with a file misnamed `.ts` is AVFoundation's guess (probed 2026-11-22: an MP4 it wrote, so
    /// named, it refused with `'optm'`; a 53 s camera MP4 and this Matroska file it opened), so the
    /// test holds on to whichever player has it.
    @Test("a .ts movie goes on too, though a .ts goes to the TypeScript sniff first")
    func transportStreamGoesOn() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.ts")
        try await MatroskaFixtures.writeMovie(to: url, seconds: 60, sound: false)
        let pane = surface(autoplay: true)
        try await open(url, on: pane)
        #expect(pane.textSurface != nil, "the first open went the TypeScript sniff's way")
        let media = try #require(pane.mediaView)
        let item = media.player.currentItem
        let player = media.sampleBufferPlayer
        #expect(media.isPlaying)

        let full = surface(autoplay: false, header: .floating)
        move(url, from: pane, to: full)

        #expect(full.textSurface == nil, "straight to the player, with nothing drawn over it")
        #expect(full.mediaView === media)
        #expect(media.player.currentItem === item, "not opened again")
        #expect(media.sampleBufferPlayer === player, "not opened again")
        #expect(media.isPlaying)
    }

    @Test("a size asked for another file stops the player it was given, as it would its own")
    func otherFileStopsIt() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await movie(in: tree)
        let pane = surface(autoplay: true)
        try await open(url, on: pane)
        let media = try #require(pane.mediaView)

        let full = surface(autoplay: false)
        pane.handOffMedia(to: full)
        pane.clear()
        full.show(try tree.write("notes.txt", contents: "hello\n"), style: .default)

        #expect(!media.isPlaying)
        #expect(!media.hasItem)
        #expect(media.isHidden)
    }

    /// A movie still opening has a read in flight on the surface that asked for it, which would put it
    /// up there whatever moved. So it stays, and putting that surface away has to make the read land
    /// nowhere: before, it went on to play the movie in a hidden surface, heard and not seen.
    @Test("a movie still opening stays behind, and the surface put away never plays it")
    func openingMovieStays() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try await movie(in: tree)
        let pane = surface(autoplay: true)
        pane.show(url, style: .default)
        #expect(!pane.hasMediaToHandOff, "the movie is still opening")
        let left = try #require(pane.mediaView)

        let full = surface(autoplay: true)
        move(url, from: pane, to: full)
        #expect(full.mediaView !== left, "nothing was handed over")
        try await settleUntil(within: Self.budget) { full.isPlayerShowing(url) }
        let opened = try #require(full.mediaView)
        // The two reads are of one file and run alike, so by the time the second has been playing for
        // half a second the first has long landed, had it been going to.
        try await settleUntil(within: Self.budget) { opened.player.currentTime().seconds > 0.5 }

        #expect(opened.isPlaying)
        #expect(!left.hasItem, "the read for the surface put away landed nowhere")
        #expect(!left.isPlaying)
    }
}
