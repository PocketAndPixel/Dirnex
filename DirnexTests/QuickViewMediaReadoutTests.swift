import AppKit
import AVFoundation
import DirnexCore
import Testing
import UniformTypeIdentifiers

@testable import Dirnex

/// What Quick View says about a movie or a sound (PLAN.md §M42 ▸ Slice 2): the header reads whether it
/// plays, where it is and what the file holds, and a file nothing here plays gets a card naming what
/// it is kept in.
@Suite("Quick View media readout")
@MainActor
struct QuickViewMediaReadoutTests {
    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Show `url` with a caption naming it, and wait for the backend to say it is on screen.
    /// A minute, for the reason `QuickViewMediaTests.show` gives.
    private func show(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
    }

    private static let budget = Duration.seconds(60)

    private func header(of view: QuickViewPreviewView) throws -> QuickViewHeaderView {
        try #require(view.headerView)
    }

    private func readout(of view: QuickViewPreviewView) -> QuickViewMediaReadout? {
        view.headerView?.caption?.media
    }

    private func movie(in tree: TempDirectory, seconds: Int = 1) async throws -> URL {
        let url = tree.root.appendingPathComponent("clip.mp4")
        try await QuickViewMediaFixtures.writeMovie(to: url, seconds: seconds)
        return url
    }

    @Test("the header reads the player's state, place and length, and what the movie holds")
    func movieReadout() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(readout(of: view))
        #expect(!media.isPlaying)
        #expect(media.time == "0:00 / 0:01")
        #expect(media.facts == "64×64 · H.264")
        let header = try header(of: view)
        #expect(!header.playbackButton.isHidden)
        #expect(header.playbackButton.title == "0:00 / 0:01")
        #expect(!header.factsLabel.isHidden)
        #expect(header.factsLabel.stringValue == "64×64 · H.264")
    }

    @Test("a sound's header has its codec and no picture")
    func soundReadout() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("tone.wav")
        try QuickViewMediaFixtures.writeSound(to: url)
        let view = surface()
        try await show(url, on: view)
        let media = try #require(readout(of: view))
        #expect(media.time == "0:00 / 0:01")
        #expect(media.facts == "PCM")
    }

    /// AVFoundation tells its periodic observer when playback starts and stops, so the header follows
    /// ⌘P without waiting for a tick; and a seek moves the place as soon as it lands. A minute-long
    /// clip, since a one-second one played to its end before a full run's poll could see it playing
    /// (2026-11-20).
    @Test("playing, pausing and a seek reach the header")
    func playbackReachesTheHeader() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree, seconds: 60), on: view)
        let media = try #require(view.mediaView)
        view.toggleMediaPlayback()
        try await settleUntil(within: Self.budget) { readout(of: view)?.isPlaying == true }
        view.toggleMediaPlayback()
        try await settleUntil(within: Self.budget) { readout(of: view)?.isPlaying == false }
        try await settleUntil(within: Self.budget) {
            media.player.currentItem?.status == .readyToPlay
        }
        view.scrollContent(.end)
        try await settleUntil(within: Self.budget) { readout(of: view)?.time == "1:00 / 1:00" }
        #expect(readout(of: view)?.time == "1:00 / 1:00")
    }

    /// The stop at the end reaches the header too. Probed 2026-11-21: the periodic observer's last
    /// report at the end comes while the rate is still 1, and the rate drops to 0 about 30 ms later
    /// with no report after it. Seen live the same day as a header left on ▶ under a clip that had
    /// stopped.
    @Test("the end of the file reaches the header")
    func endReachesTheHeader() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let media = try #require(view.mediaView)
        try await settleUntil(within: Self.budget) {
            media.player.currentItem?.status == .readyToPlay
        }
        view.toggleMediaPlayback()
        #expect(readout(of: view)?.isPlaying == true)
        try await settleUntil(within: Self.budget) { media.player.rate == 0 }
        #expect(media.player.currentTime().seconds > 0.9, "stopped by the end, not by a pause")
        try await settleUntil(within: .seconds(5)) { readout(of: view)?.isPlaying == false }
    }

    @Test("a click on the header's readout plays and pauses, without taking focus")
    func readoutClick() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        let header = try header(of: view)
        let media = try #require(view.mediaView)
        #expect(header.playbackButton.refusesFirstResponder)
        header.playbackButton.performClick(nil)
        #expect(media.isPlaying)
        header.playbackButton.performClick(nil)
        #expect(!media.isPlaying)
    }

    /// The control for the three above: the readout belongs to the player, so a file that is not a
    /// movie takes it off the header.
    @Test("stepping to a file that is not a movie takes the readout away")
    func readoutLeavesWithTheMovie() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let view = surface()
        try await show(try movie(in: tree), on: view)
        #expect(readout(of: view) != nil)
        try await show(try tree.write("notes.txt", contents: "hello\n"), on: view)
        #expect(readout(of: view) == nil)
        let header = try header(of: view)
        #expect(header.playbackButton.isHidden)
        #expect(header.factsLabel.isHidden)
    }

    @Test("a file nothing plays gets a card naming its container, and no readout")
    func cardNamesTheContainer() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try QuickViewMediaFixtures.matroskaHeader.write(to: url)
        let view = surface()
        try await show(url, on: view)
        let card = try #require(view.mediaView?.card)
        #expect(!card.isHidden)
        #expect(card.nameLabel.stringValue == "film.mkv")
        #expect(card.detailLabel.stringValue == "Matroska")
        #expect(card.hintLabel.stringValue == QuickViewMediaCard.hint)
        #expect(readout(of: view) == nil, "nothing plays, so nothing says where it has got to")
    }

    /// AVFoundation says nothing about a Matroska file, so before Slice 3 the card stopped at
    /// "Matroska". The file's own tracks say the rest.
    @Test("a Matroska file's card names its picture and codecs from the file's own tracks")
    func cardReadsMatroskaTracks() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try QuickViewMediaFixtures.matroskaHead.write(to: url)
        let view = surface()
        try await show(url, on: view)
        let card = try #require(view.mediaView?.card)
        #expect(view.mediaView?.showsCard == true)
        #expect(card.detailLabel.stringValue == "Matroska · 1816×1080 · H.264 · AC-3, DTS")
    }

    /// The bytes decide over the name: a WebM file named `.mkv` is called WebM.
    @Test("the card names what the bytes say, not what the name says")
    func cardReadsTheBytes() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.mkv")
        // An EBML header holding only a DocType of "webm".
        try Data([0x1A, 0x45, 0xDF, 0xA3, 0x87, 0x42, 0x82, 0x84] + Array("webm".utf8)).write(
            to: url
        )
        let view = surface()
        try await show(url, on: view)
        #expect(view.mediaView?.card.detailLabel.stringValue == "WebM")
    }

    /// A container macOS leaves untyped reaches the card too. On the Mac this was written on, VLC
    /// declared `.mkv` and `.mka` and nothing declared `.mk3d`, which is the case of a `.mkv` on a Mac
    /// without VLC.
    @Test("a container with no type of its own still reaches the card")
    func untypedContainer() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mk3d")
        try QuickViewMediaFixtures.matroskaHeader.write(to: url)
        #expect(QuickViewPreviewView.isMedia(url))
        let view = surface()
        try await show(url, on: view)
        #expect(view.mediaView?.showsCard == true)
        #expect(view.mediaView?.card.detailLabel.stringValue == "Matroska")
        #expect(view.textSurface?.isHidden != false, "it does not go through the text preview")
    }

    @Test("a System Profiler report named .spx is not taken for Speex")
    func profilerReportIsNotMedia() {
        #expect(!QuickViewPreviewView.isMedia(URL(fileURLWithPath: "/tmp/report.spx")))
    }

    // MARK: - Layout

    /// A header `width` wide in a window, captioned as a movie, laid out.
    private func header(width: CGFloat, name: String) throws -> (QuickViewHeaderView, NSWindow) {
        let hosted = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let header = QuickViewHeaderView(material: .headerView)
        let content = try #require(hosted.contentView)
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        var caption = QuickViewCaption(name: name, position: 2, count: 21)
        caption.media = QuickViewMediaReadout(
            isPlaying: true,
            time: "0:42 / 1:35:20",
            facts: "2560×1440 · H.264 · AAC"
        )
        header.caption = caption
        content.layoutSubtreeIfNeeded()
        return (header, hosted)
    }

    private func laidOut(_ view: NSView) -> NSRect {
        QuickViewCloseButtonTests.laidOut(view)
    }

    @Test("the readout leads, the facts sit before the position, and the name keeps clear of both")
    func layoutWithRoom() throws {
        let (header, hosted) = try header(width: 900, name: "clip.mp4")
        defer { withExtendedLifetime(hosted) {} }
        let readout = laidOut(header.playbackButton)
        let facts = laidOut(header.factsLabel)
        let close = laidOut(header.closeButton)
        let name = laidOut(try QuickViewCloseButtonTests.label(in: header, reading: "clip.mp4"))
        let position = laidOut(try QuickViewCloseButtonTests.label(in: header, reading: "2 of 21"))
        #expect(readout.minX == 12)
        #expect(name.minX >= readout.maxX + 12)
        #expect(close.maxX <= facts.minX - 12)
        #expect(abs(facts.maxX - (position.minX - 10)) <= 1)
        #expect(position.maxX == 888)
        #expect(facts.width >= header.factsLabel.intrinsicContentSize.width - 4, "nothing cut")
    }

    /// The narrowness control: in a pane too short for everything, the facts give way first, and
    /// neither the clock nor the position is what gets squeezed.
    @Test("short of room, the facts give way before the clock or the position")
    func layoutShortOfRoom() throws {
        let long = String(repeating: "Treasure Planet ", count: 6) + ".mkv"
        let (header, hosted) = try header(width: 400, name: long)
        defer { withExtendedLifetime(hosted) {} }
        let readout = laidOut(header.playbackButton)
        let facts = laidOut(header.factsLabel)
        let close = laidOut(header.closeButton)
        let position = laidOut(try QuickViewCloseButtonTests.label(in: header, reading: "2 of 21"))
        #expect(facts.width < header.factsLabel.intrinsicContentSize.width - 4)
        #expect(readout.width >= header.playbackButton.intrinsicContentSize.width - 4)
        #expect(close.maxX <= facts.minX - 12)
        #expect(position.maxX == 388)
        #expect(header.factsLabel.toolTip == "2560×1440 · H.264 · AAC", "the whole of it on hover")
    }

    /// The case AVFoundation opens and will not play, which needs a codec this Mac cannot decode inside
    /// a container it reads. No system encoder writes one, so the card's line is pinned on its own.
    @Test("the card's line is the container, then whatever AVFoundation read")
    func cardDetail() {
        let dts = QuickViewMediaCard.Content(
            name: "film.mp4",
            container: "MPEG-4",
            summary: MediaSummary(audioCodecs: ["DTS", "DTS"])
        )
        #expect(dts.detail == "MPEG-4 · DTS")
        let bare = QuickViewMediaCard.Content(name: "film.xyz", container: nil, summary: nil)
        #expect(bare.detail.isEmpty)
    }
}
