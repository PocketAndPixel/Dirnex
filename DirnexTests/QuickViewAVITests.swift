import AppKit
import AVFoundation
import DirnexCore
import Testing
import VideoToolbox

@testable import Dirnex

/// AVI in Quick View's player (PLAN.md §M42 ▸ Slice 5): AVFoundation refuses the container, the core
/// reads it, and the player Matroska plays through plays it.
///
/// The files are made from packets the system's own encoders wrote (`AVIFixtures`). VideoToolbox's
/// H.264 encoder writes B-frames and states when each picture is shown, which an AVI throws away, so
/// the times the reader works out from the slices are held to the encoder's own.
@Suite("Quick View AVI player")
@MainActor
struct QuickViewAVITests {
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

    private func show(_ url: URL, on view: QuickViewPreviewView) async throws {
        view.show(url, style: .default)
        view.setCaption(QuickViewCaption(name: url.lastPathComponent, position: 1, count: 3))
        try await settleUntil(within: Self.budget) { !view.flipGate.isLoading }
        view.layoutSubtreeIfNeeded()
    }

    private static let budget = Duration.seconds(60)

    @Test(
        "an AVI of H.264 and AAC plays in the core's player, paused, its facts from its own headers"
    )
    func opensInThePlayer() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.avi")
        _ = try AVIFixtures.writeMovie(to: url)
        let view = surface()
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer, "the core's player, not the card")
        #expect(!media.showsCard && !media.sampleBufferView.isHidden)
        #expect(media.hasItem && !media.isPlaying, "nothing plays until it is asked to")
        #expect(player.displayLayer != nil)
        let readout = try #require(view.headerView?.caption?.media)
        #expect(readout.facts == "64×64 · H.264 · AAC")
        #expect(readout.time == "0:00 / 0:01")
    }

    @Test("⌘P plays it, every picture decoding and the AAC taken, and pauses it")
    func playAndPause() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.avi")
        _ = try AVIFixtures.writeMovie(to: url, seconds: 20)
        let view = surface()
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        let player = try #require(media.sampleBufferPlayer)
        media.togglePlayback()
        try await settleUntil(within: Self.budget) { player.currentSeconds > 0.5 }
        media.togglePlayback()
        #expect(!media.isPlaying)
        if #available(macOS 14.4, *) {
            let metrics = try #require(
                await player.displayLayer?.sampleBufferRenderer.videoPerformanceMetrics
            )
            #expect(metrics.totalNumberOfFrames > 0)
            #expect(metrics.numberOfCorruptedFrames == 0, "every picture decoded")
        }
        #expect(player.audioError == nil, "the AAC was taken")
    }

    @Test(
        "each B-frame comes out at the time VideoToolbox's encoder gave it, which the AVI did not keep"
    )
    func encoderTimes() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.avi")
        let h264 = try AVIFixtures.writeMovie(to: url, seconds: 2, sound: false)
        let frames = h264.pictures.map(\.frame)
        try #require(
            frames != frames.sorted(),
            "the encoder wrote B-frames, or this measures nothing"
        )
        let file = try AVIFile(source: FileByteSource(url: url))
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        var times: [Int64] = []
        while let packet = try demuxer.next(track: 0) {
            times.append(packet.time)
        }
        #expect(times == frames.map { Int64($0) * 40_000_000 })
    }

    @Test("every picture decodes through the bridge, and shown in time order the frames brighten")
    func decodesInOrder() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.avi")
        _ = try AVIFixtures.writeMovie(to: url, seconds: 2, sound: false)
        let shown = try decoded(url)
        #expect(shown.count == 50)
        #expect(
            shown.map(\.corner) == shown.map(\.corner).sorted(),
            "each frame's background a step up"
        )
    }

    @Test("a Motion JPEG frame without its tables decodes to the same picture as with them")
    func motionJPEG() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        func write(_ name: String, stripped: Bool) throws -> URL {
            let url = tree.root.appendingPathComponent(name)
            let frames = try (0..<5).map { index -> Data in
                let jpeg = try AVIFixtures.jpeg(index * 10)
                return stripped ? AVIFixtures.withoutTables(jpeg) : jpeg
            }
            try AVIFixtures.write([AVIFixtures.Stream(
                handler: "MJPG",
                format: AVIFixtures.videoFormat(compression: "MJPG"),
                chunks: frames.enumerated().map { AVIFixtures.Chunk(
                    data: $1,
                    seconds: Double($0) / 25
                ) }
            )], to: url)
            return url
        }
        let whole = try decoded(write("whole.avi", stripped: false))
        let stripped = try decoded(write("stripped.avi", stripped: true))
        #expect(whole.count == 5)
        #expect(stripped.map(\.fingerprint) == whole.map(\.fingerprint))
    }

    @Test("an AVI whose picture nothing here decodes gets the card, naming AVI and the codec")
    func refusedCodec() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("old.avi")
        try AVIFixtures.write([AVIFixtures.Stream(
            handler: "DIV3",
            format: AVIFixtures.videoFormat(compression: "DIV3"),
            chunks: [AVIFixtures.Chunk(data: Data([1, 2, 3, 4]), seconds: 0)]
        )], to: url)
        let view = surface()
        try await show(url, on: view)
        let media = try #require(view.mediaView)
        #expect(media.sampleBufferPlayer == nil && media.showsCard)
        #expect(media.card.detailLabel.stringValue == "AVI · 64×64 · MPEG-4 v3")
    }

    /// One decoded picture: when it is shown, the grey of its top-left corner, and a fingerprint of
    /// every pixel.
    private struct Decoded {
        let time: Int64
        let corner: Int
        let fingerprint: Int
    }

    /// Every picture of the AVI at `url`, decoded by VideoToolbox through the bridge in the order the
    /// demuxer hands them over, by the time it is shown: the grey of its top-left corner, and a
    /// fingerprint of every pixel.
    private func decoded(_ url: URL) throws -> [Decoded] {
        let file = try AVIFile(source: FileByteSource(url: url))
        let index = try file.index()
        let stream = file.streams[0]
        let first = try index.entries(0).first { $0.size > 0 }.map(file.read)
        let format = try #require(stream.sampleFormat(firstFrame: first))
        let description = try #require(MediaSampleBridge.formatDescription(format))
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        #expect(VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        ) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        var demuxer = try AVIDemuxer(file: file, index: index, streams: [stream])
        var shown: [Decoded] = []
        while let packet = try demuxer.next(track: 0) {
            let sample = try #require(
                MediaSampleBridge.sampleBuffer(packet, description: description, audio: nil)
            )
            VTDecompressionSessionDecodeFrame(
                decoder,
                sampleBuffer: sample,
                flags: [],
                infoFlagsOut: nil
            ) { status, _, image, _, _ in
                guard status == noErr, let image else { return }
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(image)
                var fingerprint = 0
                for y in 0..<CVPixelBufferGetHeight(image) {
                    for x in 0..<CVPixelBufferGetWidth(image) * 4 {
                        fingerprint = fingerprint &* 31 &+ Int(pixels[y * row + x])
                    }
                }
                shown.append(
                    Decoded(time: packet.time, corner: Int(pixels[1]), fingerprint: fingerprint)
                )
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        return shown.sorted { $0.time < $1.time }
    }
}
