import Foundation
import Testing

@testable import DirnexCore

/// The reader against the AVI sample on this Mac (PLAN.md §M42 ▸ Slice 5), captured sparsely
/// (docs/NOTES.md ▸ Testing ▸ Fixtures): `lavf-x264-aac.avi`, 35 MB, made by Lavf with x264 core 164
/// (three B-frames, a B-pyramid) and AAC behind ADTS headers, as 117 KB holding its headers, its
/// `idx1`, the first bytes of every picture chunk (the parameter sets and the first slice header) and
/// the ADTS headers of its first 64 sound chunks.
///
/// The expected numbers come from a separate walk in Python over the whole file, and the display order
/// was checked a third way: decoded by VideoToolbox in that order, the frames change half as much from
/// one to the next as in the order they are stored (a mean step of 1 376 against 2 538).
@Suite("AVI sample")
struct AVICapturedTests {
    static func open() throws -> AVIFile {
        try AVIFile(source: SparseCaptureSource(fixture: "lavf-x264-aac.avi", folder: "AVI"))
    }

    @Test("the headers: H.264 at 25 frames a second and AAC, 53.76 seconds, as the card names them")
    func headers() throws {
        let file = try Self.open()
        #expect(file.streams.map(\.kind) == [.video, .audio])
        #expect(file.streams[1].scale == 8 && file.streams[1].rate == 375, "1024 samples at 48 kHz")
        #expect(file.durationSeconds == 53.76)
        #expect(MediaSummary(avi: file).facts == "1920×1080 · H.264 · AAC")
    }

    @Test("the index: idx1, 1 344 pictures with a key frame every 250, and 2 524 sound chunks")
    func index() throws {
        let index = try Self.open().index()
        #expect(index.origin == .legacy)
        #expect(index.streams.map(\.count) == [1344, 2524])
        #expect(
            index.streams[0].indices.filter { index.streams[0][$0].isKeyframe } == [
                0,
                250,
                500,
                750,
                1000,
                1250
            ]
        )
    }

    @Test("the picture's configuration is made from the parameter sets in its first frame")
    func format() throws {
        let file = try Self.open()
        let index = try file.index()
        let first = try file.read(index.streams[0][0])
        guard case let .video(video)? = file.streams[0].sampleFormat(firstFrame: first) else {
            Issue.record("no picture format")
            return
        }
        #expect(video.codec == MediaSampleFormat.code("avc1"))
        #expect(video.width == 1920 && video.height == 1080)
        let units = H264NALUnits.annexB(first)
        let record = H264Configuration.record(
            sequence: try #require(units.first { H264NALUnits.type($0) == 7 }),
            picture: try #require(units.first { H264NALUnits.type($0) == 8 })
        )
        #expect(video.atoms["avcC"] == record)
        #expect(units.first == H264BitstreamTests.sampleSequence)
    }

    @Test("every picture, in stored order, at the tick Python's walk shows it at")
    func displayOrder() throws {
        let file = try Self.open()
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        var ticks: [Int64] = []
        while let packet = try demuxer.next(track: 0) {
            ticks.append(packet.time / 40_000_000)
        }
        #expect(ticks.count == 1344)
        #expect(Array(ticks.prefix(13)) == [0, 4, 2, 1, 3, 8, 6, 5, 7, 12, 10, 9, 11])
        #expect(
            ticks.enumerated().reduce(0) { $0 + Int64($1.offset + 1) * $1.element } == 809_235_818
        )
        #expect(Set(ticks).count == 1344)
    }

    @Test(
        "the sound: ADTS headers off, and the muxer's two empty chunks a gap, as FFmpeg times them"
    )
    func sound() throws {
        let file = try Self.open()
        let index = try file.index()
        var demuxer = try AVIDemuxer(file: file, index: index, streams: file.streams)
        let packets = try (0..<4).compactMap { _ in try demuxer.next(track: 1) }
        #expect(packets.map(\.time) == [0, 64_000_000, 85_333_333, 106_666_667])
        #expect(packets.map(\.data.count) == [334, 334, 335, 334])
        let first = try file.read(index.streams[1][0])
        guard case let .audio(format)? = file.streams[1].sampleFormat(firstFrame: first) else {
            Issue.record("no sound format")
            return
        }
        #expect(
            format.magicCookie == AACConfiguration.magicCookie(
                audioSpecificConfig: Data([0x11, 0x90])
            )
        )
    }

    @Test("a seek to 21 s starts at the key frame at 20 s, the second between shown as preroll")
    func seek() throws {
        let file = try Self.open()
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        demuxer.seek(to: 21_000_000_000)
        let packets = try (0..<40).compactMap { _ in try demuxer.next(track: 0) }
        #expect(packets.first?.time == 20_000_000_000)
        #expect(packets.first?.isKeyframe == true)
        #expect(packets.allSatisfy { $0.isPreroll == ($0.time < 21_000_000_000) })
        #expect(packets.contains { !$0.isPreroll })
    }
}
