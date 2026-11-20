import AppKit
import AVFoundation
import DirnexCore
import Testing
import VideoToolbox

@testable import Dirnex

/// Matroska and WebM in Quick View's player (PLAN.md §M42 ▸ Slice 4): AVFoundation refuses the
/// container, the core reads it, and the system's decoders play what the core hands over through
/// sample-buffer renderers.
///
/// The files are made from packets the system's own encoders wrote (`MatroskaFixtures`), and the
/// decode tests hold the bridge to what AudioToolbox and VideoToolbox accept, with a tone loud enough
/// that a decoder producing silence fails.
@Suite("Quick View Matroska player")
@MainActor
struct QuickViewMatroskaTests {
    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Show `url` and wait for the backend to say it is on screen. A minute, for the reason
    /// `QuickViewMediaTests.show` gives.
    private func show(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
    }

    private static let budget = Duration.seconds(60)

    private func film(in tree: TempDirectory, seconds: Int = 1, sound: Bool = true) async throws -> URL {
        let url = tree.root.appendingPathComponent("film.mkv")
        try await MatroskaFixtures.writeMovie(to: url, seconds: seconds, sound: sound)
        return url
    }

    @Test("a Matroska file this Mac decodes plays in the core's player, paused, with no card")
    func opensInThePlayer() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree), on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer, "the core's player, not the card")
        #expect(!media.showsCard)
        #expect(!media.sampleBufferView.isHidden && media.playerView.isHidden)
        #expect(media.hasItem && !media.isPlaying, "nothing plays until it is asked to")
        #expect(player.displayLayer != nil)
        #expect(view.previewView?.isHidden != false, "Quick Look is put away")
        guard case .media = view.contentTarget else {
            Issue.record("⌘P and the ⇧-keys find the player through the content target")
            return
        }
        let readout = try #require(view.headerView?.caption?.media)
        #expect(readout.facts == "64×64 · H.264 · AAC")
        #expect(readout.time == "0:00 / 0:01")
    }

    @Test("⌘P runs the clock and the pictures, and pauses them")
    func playAndPause() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree, seconds: 60), on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer)
        media.togglePlayback()
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.3 }
        media.togglePlayback()
        #expect(!media.isPlaying)
        let paused = player.currentSeconds
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(player.currentSeconds - paused) < 0.05, "a paused clock stays")
        if #available(macOS 14.4, *) {
            let metrics = try #require(
                await player.displayLayer?.sampleBufferRenderer.videoPerformanceMetrics
            )
            #expect(metrics.totalNumberOfFrames > 0)
            #expect(metrics.numberOfCorruptedFrames == 0, "every picture decoded")
        }
        #expect(player.audioError == nil, "the AAC was taken")
    }

    /// The file's stated length and the end of its data differ by a packet: the Steam clip states
    /// 4.008 s and its last Opus packet ends at 4.021 s, and this fixture's AAC runs past its second.
    /// Seen live 2026-11-20: waiting for the clock to pass the later of the two, while the clock is
    /// held at the earlier, left the player saying it played forever.
    @Test("at the end it pauses, and ⌘P plays again from the start")
    func pausesAtTheEnd() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree), on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer)
        media.togglePlayback()
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { !media.isPlaying }
        #expect(player.currentSeconds > 0.95, "at \(player.currentSeconds) s")
        media.togglePlayback()
        #expect(media.isPlaying)
        try await settleUntil(within: Self.budget) { player.currentSeconds < 0.5 }
        media.togglePlayback()
    }

    @Test("⇧→ goes to the end and ⇧← back to the start, and the timeline follows")
    func shiftKeysSeek() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree, seconds: 10), on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer)
        view.scrollContent(.end)
        try await settleUntil(within: Self.budget) { player.currentSeconds > 9.9 }
        #expect(media.sampleBufferView.timeline.doubleValue > 9.9)
        view.scrollContent(.top)
        try await settleUntil(within: Self.budget) { player.currentSeconds < 0.05 }
        #expect(media.sampleBufferView.timeline.doubleValue < 0.05)
        view.scrollContent(.lineDown)
        try await settleUntil(within: Self.budget) { abs(player.currentSeconds - 10) < 0.05 }
    }

    @Test("a move of the timeline seeks the player")
    func timelineSeeks() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree, seconds: 10), on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer)
        let timeline = media.sampleBufferView.timeline
        #expect(timeline.maxValue == 10 && timeline.isEnabled)
        timeline.doubleValue = 4
        timeline.sendAction(timeline.action, to: timeline.target)
        try await settleUntil(within: Self.budget) { abs(player.currentSeconds - 4) < 0.05 }
        #expect(view.headerView?.caption?.media?.time == "0:04 / 0:10")
    }

    @Test("the timeline takes the mouse, while the picture keeps swallowing it")
    func timelineTakesTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = view
        try await show(try film(in: tree), on: view)
        let media = try #require(view.mediaView)
        let timeline = media.sampleBufferView.timeline
        let center = timeline.convert(
            NSPoint(x: timeline.bounds.midX, y: timeline.bounds.midY),
            to: view.superview
        )
        let hit = try #require(view.hitTest(center))
        #expect(
            hit === timeline || hit.isDescendant(of: timeline),
            "a click on the timeline must reach it"
        )
        #expect(
            view.hitTest(NSPoint(x: 400, y: 300)) === view,
            "over the picture the surface swallows"
        )
    }

    @Test("stepping to another file stops the player and lets the file go")
    func steppingAwayStops() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try film(in: tree), on: view)
        let media = try #require(view.mediaView)
        media.togglePlayback()
        try await show(try tree.write("notes.txt", contents: "hello\n"), on: view)
        #expect(media.sampleBufferPlayer == nil)
        #expect(!media.isPlaying && !media.hasItem)
        #expect(media.isHidden && media.sampleBufferView.isHidden)
        #expect(
            media.sampleBufferView.pictureView.layer?.sublayers?.isEmpty ?? true,
            "the picture is let go"
        )
    }

    @Test("a picture nothing here decodes still gets the card")
    func vp8GetsTheCard() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.webm")
        let frames = (0..<5).map { MatroskaFixtures.Packet(
            data: Data([0x10, 0x02, 0x00, 0x9D, 0x01, 0x2A]),
            milliseconds: $0 * 40
        ) }
        try MatroskaFixtures.write(
            [
                MatroskaFixtures.Track(
                    number: 1,
                    isVideo: true,
                    codecID: "V_VP8",
                    codecPrivate: nil,
                    packets: frames
                )
            ],
            duration: 0.2,
            docType: "webm",
            to: url
        )
        let view = surface()
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        #expect(media.sampleBufferPlayer == nil && media.showsCard)
        #expect(media.card.detailLabel.stringValue == "WebM · 64×64 · VP8")
    }

    @Test("the tooltip names each sound, the one playing and the ones that cannot play")
    func soundLines() {
        func track(_ number: UInt64, _ codec: String, _ language: String, isDefault: Bool) -> MatroskaTrack {
            var track = MatroskaTrack()
            track.number = number
            track.kind = .audio
            track.codecID = codec
            track.language = language
            track.isDefault = isDefault
            var audio = MatroskaTrack.Audio()
            audio.channels = 6
            track.audio = audio
            return track
        }
        let plan = MatroskaPlaybackPlan(
            tracks: [
                track(2, "A_AC3", "rus", isDefault: true),
                track(3, "A_DTS", "eng", isDefault: false)
            ],
            canDecode: { $0.codecID != "A_DTS" }
        )
        let russian = Locale.current.localizedString(forLanguageCode: "rus") ?? "rus"
        let english = Locale.current.localizedString(forLanguageCode: "eng") ?? "eng"
        let lines = QuickViewMediaView.soundLines(
            SampleBufferPreparation.sounds(plan),
            playing: plan.audio?.number
        )
        #expect(lines.first == "▶ \(russian) · AC-3 · 5.1")
        #expect(lines.last?.hasPrefix("\(english) · DTS · 5.1") == true)
        #expect(lines.last != "\(english) · DTS · 5.1", "an undecodable track says so")
        let single = MatroskaPlaybackPlan(
            tracks: [track(2, "A_AC3", "und", isDefault: true)],
            canDecode: { _ in true }
        )
        #expect(
            QuickViewMediaView.soundLines(SampleBufferPreparation.sounds(single), playing: 2).isEmpty,
            "one sound that plays needs no list"
        )
    }
}
