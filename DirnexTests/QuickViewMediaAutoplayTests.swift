import AppKit
import AVFoundation
import Testing

@testable import Dirnex

/// A movie or a sound plays from its start once Quick View has it up, when Settings ▸ Panels says so,
/// as it does by default (PLAN.md §M42, asked 2026-11-21).
///
/// The surface asks `autoplaysMedia` each time a file goes up. It answers no unless the window hands
/// over Settings' answer, which is why the other player tests still open paused. Every fixture here is
/// silent, so a run is not heard.
@Suite("Quick View ▸ movies and sounds play on their own")
@MainActor
struct QuickViewMediaAutoplayTests {
    private func surface(autoplay: Bool) -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        view.autoplaysMedia = { autoplay }
        return view
    }

    /// Show `url` with a caption naming it, and wait for the backend to say it is on screen. A minute,
    /// for the reason `QuickViewMediaTests.show` gives.
    private func show(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
    }

    private static let budget = Duration.seconds(60)

    /// A minute long, so it is still playing when a slow full run gets round to looking: under one the
    /// main actor has waited past ten seconds for its turn.
    private func movie(in tree: TempDirectory, named name: String = "clip.mp4") async throws -> URL {
        let url = tree.root.appendingPathComponent(name)
        try await QuickViewMediaFixtures.writeMovie(to: url, seconds: 60)
        return url
    }

    @Test("a movie plays from its start once it is up, and the header says so")
    func moviePlays() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface(autoplay: true)
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        #expect(media.isPlaying)
        #expect(view.headerView?.caption?.media?.isPlaying == true, "the header reads ▶")
        try await settleUntil(within: Self.budget) { media.player.currentTime().seconds > 0.2 }
        media.togglePlayback()
        #expect(!media.isPlaying, "⌘P pauses it as it would any other")
    }

    @Test("a sound plays once it is up, and stops when Quick View closes")
    func soundPlays() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("tone.wav")
        try QuickViewMediaFixtures.writeSound(to: url, seconds: 30)
        let view = surface(autoplay: true)
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { media.player.currentTime().seconds > 0.2 }
        view.clear()
        #expect(!media.isPlaying)
        #expect(!media.hasItem)
    }

    /// The core's player is asked to play before its feed has handed the renderers a packet, so this
    /// is also the check that the clock and the pictures still start from there, with the sound taken.
    @Test("a Matroska file the core plays starts too, and stepping away stops it")
    func matroskaPlays() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try await MatroskaFixtures.writeMovie(to: url, seconds: 60)
        let view = surface(autoplay: true)
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer, "the core's player, not the card")
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.3 }
        if #available(macOS 14.4, *) {
            let metrics = try #require(
                await player.displayLayer?.sampleBufferRenderer.videoPerformanceMetrics
            )
            #expect(metrics.totalNumberOfFrames > 0)
            #expect(metrics.numberOfCorruptedFrames == 0)
        }
        #expect(player.audioError == nil, "the AAC was taken")
        try await show(try tree.write("notes.txt", contents: "hello\n"), on: view)
        #expect(!media.isPlaying)
        #expect(!media.hasItem)
    }

    /// The control for the three above, from the same surface: turned off between two files, the
    /// second opens paused, which also shows the answer is asked per file rather than kept.
    @Test("the setting is asked for each file, so turning it off leaves the next one paused")
    func askedForEachFile() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        var autoplay = true
        let view = surface(autoplay: false)
        view.autoplaysMedia = { autoplay }
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        #expect(media.isPlaying)

        autoplay = false
        try await show(try movie(in: tree, named: "other.mp4"), on: view)
        #expect(media.hasItem)
        #expect(!media.isPlaying, "off, a movie waits for ⌘P")
        #expect(view.headerView?.caption?.media?.isPlaying == false)
    }
}

/// Settings ▸ Panels ▸ Play video and audio automatically in Quick View: on for a fresh install, kept
/// when turned off, and what the window's surfaces ask.
@Suite("Quick View autoplay preference")
@MainActor
struct QuickViewAutoplayPreferenceTests {
    /// `bool(forKey:)` answers false for a key never written, which would ship the feature off.
    @Test("a fresh install plays movies and sounds on their own")
    func onByDefault() {
        #expect(AppPreferences(defaults: ScratchDefaults.fresh()).quickViewAutoplayMedia)
    }

    @Test("turned off, it stays off after a relaunch, and on again when turned back on")
    func roundTrips() {
        let defaults = ScratchDefaults.fresh()
        AppPreferences(defaults: defaults).quickViewAutoplayMedia = false
        #expect(!AppPreferences(defaults: defaults).quickViewAutoplayMedia)
        AppPreferences(defaults: defaults).quickViewAutoplayMedia = true
        #expect(AppPreferences(defaults: defaults).quickViewAutoplayMedia)
    }

    /// The wiring, without writing the domain of whoever runs the suite: the pane's surface answers
    /// what Settings does. It tells the wiring from the surface's own default only while Settings
    /// holds the default, on, as an untouched test host does.
    @Test("a pane's Quick View asks Settings")
    func paneAsksSettings() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "hello\n")
        let panes = try QuickViewPaneSplit()
        let caption = QuickViewCaption(name: url.lastPathComponent, position: 1, count: 1)
        panes.right.showQuickViewPreview(of: url, style: .default, caption: caption)
        let surface = try #require(panes.right.quickViewPreview)
        #expect(surface.autoplaysMedia() == AppPreferences.shared.quickViewAutoplayMedia)
    }
}
