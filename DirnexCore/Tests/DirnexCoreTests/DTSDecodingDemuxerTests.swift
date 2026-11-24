import Foundation
import Testing

@testable import DirnexCore

/// DTS handed to a player as PCM (PLAN.md §M42 ▸ DTS): the decoded format, the packets a
/// `DTSDecodingDemuxer` turns DTS frames into, and DTS inside an AVI, cut into frames by its headers.
@Suite("DTS decoding demuxer")
struct DTSDecodingDemuxerTests {
    /// A demuxer handing out packets it was given, track by track, and noting where it is sent.
    struct Scripted: MediaDemuxing {
        var packets: [UInt64: [MediaPacket]]
        var positions: [UInt64: Int] = [:]
        var seeks: [Int64] = []

        mutating func next(track: UInt64) throws -> MediaPacket? {
            let position = positions[track, default: 0]
            guard let list = packets[track], position < list.count else { return nil }
            positions[track] = position + 1
            return list[position]
        }

        mutating func seek(to nanoseconds: Int64, keyTrack _: UInt64?) throws {
            seeks.append(nanoseconds)
            positions = [:]
        }
    }

    static let step: Int64 = 10_666_667

    static func packet(_ data: Data, track: UInt64 = 2, index: Int) -> MediaPacket {
        MediaPacket(
            track: track,
            time: Int64(index) * step,
            duration: step,
            data: data,
            isKeyframe: true,
            frameCount: nil,
            isPreroll: false
        )
    }

    static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    @Test("the decoded format: float PCM at the frame's rate, its layout's channels and tag")
    func decodedFormat() throws {
        let frame = try #require(
            try DTSCoreDecoderTests.frames(DTSCoreDecoderTests.fixture("lavc-51-adpcm")).first
        )
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frame))
        #expect(format.formatID == MediaSampleFormat.code("lpcm"))
        #expect(format.sampleRate == 48000 && format.channels == 6 && format.framesPerPacket == 1)
        #expect(format.pcm == .init(bitsPerSample: 32, isFloat: true, isBigEndian: false))
        #expect(format.channelLayoutTag == UInt32(121 << 16 | 6))
        #expect(MediaSampleFormat.Audio.decodedDTS(firstFrame: Data(repeating: 0, count: 64)) == nil)
    }

    @Test("DTS packets come out as the decoder's samples, at their times; other tracks pass through")
    func packets() throws {
        let frames = try DTSCoreDecoderTests.frames(DTSCoreDecoderTests.fixture("lavc-51-adpcm"))
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frames[0]))
        let picture = Self.packet(Data([1, 2, 3]), track: 1, index: 0)
        var demuxer = DTSDecodingDemuxer(
            Scripted(
                packets: [1: [picture], 2: frames.enumerated().map { Self.packet($1, index: $0) }]
            ),
            decoding: [2: format]
        )
        #expect(try demuxer.next(track: 1) == picture)
        var reference = DTSCoreDecoder()
        for (index, frame) in frames.prefix(4).enumerated() {
            let packet = try #require(try demuxer.next(track: 2))
            // Timed by the samples: index × 512 at 48 kHz, to the nanosecond.
            #expect(packet.time == Int64((Double(index * 512) * 1e9 / 48000).rounded()))
            #expect(packet.frameCount == 512 && [10_666_666, 10_666_667].contains(packet.duration))
            #expect(packet.data.count == 512 * 6 * 4)
            #expect(Self.floats(packet.data) == (try reference.decode(frame)).samples)
        }
    }

    @Test("a frame that does not decode plays as silence of its length, and the next one decodes")
    func badFrame() throws {
        let frames = try DTSCoreDecoderTests.frames(DTSCoreDecoderTests.fixture("lavc-stereo"))
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frames[0]))
        let garbage = Data(repeating: 0x55, count: 700)
        var demuxer = DTSDecodingDemuxer(
            Scripted(packets: [2: [
                Self.packet(frames[0], index: 0),
                Self.packet(garbage, index: 1),
                Self.packet(frames[2], index: 2)
            ]]),
            decoding: [2: format]
        )
        _ = try demuxer.next(track: 2)
        let silent = try #require(try demuxer.next(track: 2))
        #expect(silent.frameCount == 512 && Self.floats(silent.data).allSatisfy { $0 == 0 })
        let after = try #require(try demuxer.next(track: 2))
        var fresh = DTSCoreDecoder()
        #expect(Self.floats(after.data) == (try fresh.decode(frames[2])).samples, "decoded afresh")
    }

    @Test("a seek reaches the demuxer underneath and starts the decoder afresh")
    func seek() throws {
        let frames = try DTSCoreDecoderTests.frames(DTSCoreDecoderTests.fixture("lavc-51-adpcm"))
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frames[0]))
        var demuxer = DTSDecodingDemuxer(
            Scripted(packets: [2: frames.enumerated().map { Self.packet($1, index: $0) }]),
            decoding: [2: format]
        )
        var warm = DTSCoreDecoder()
        for frame in frames.prefix(5) {
            _ = try demuxer.next(track: 2)
            _ = try warm.decode(frame)
        }
        try demuxer.seek(to: 0, keyTrack: nil)
        var fresh = DTSCoreDecoder()
        let first = try #require(try demuxer.next(track: 2))
        #expect(Self.floats(first.data) == (try fresh.decode(frames[0])).samples)
        // The negative control: a decoder that was not reset gives other samples for the same frame.
        #expect(Self.floats(first.data) != (try warm.decode(frames[0])).samples)
    }

    /// Seen live 2026-11-24: mkvmerge stamps each block of eight 10.667 ms frames in whole milliseconds,
    /// so the frames' stated times fall up to 666 µs off where the frame before ended, and the PCM
    /// played with a click at each join.
    @Test(
        "decoded packets join end to end, though the container's times are rounded to the millisecond"
    )
    func continuousTimes() throws {
        let frames = try DTSCoreDecoderTests.frames(DTSCoreDecoderTests.fixture("lavc-stereo"))
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: frames[0]))
        // Eight frames a block, each block stamped at its start rounded to the millisecond, as mkvmerge does.
        let stated = (0..<24).map { index -> Int64 in
            let blockStart = (Double(index / 8 * 8 * 512) / 48).rounded() * 1_000_000
            return Int64(blockStart) + Int64(index % 8) * Self.step
        }
        let packets = frames.indices.map { index in
            MediaPacket(
                track: 2,
                time: stated[index],
                duration: Self.step,
                data: frames[index],
                isKeyframe: true,
                frameCount: nil,
                isPreroll: false
            )
        }
        var demuxer = DTSDecodingDemuxer(Scripted(packets: [2: packets]), decoding: [2: format])
        #expect(
            zip(stated.dropFirst(), stated).contains { $0 - $1 != Self.step },
            "the stated times are rounded"
        )
        var end: Int64 = 0
        var joins = 0
        while let packet = try demuxer.next(track: 2) {
            if packet.time != end { joins += 1 }
            end = packet.time + (packet.duration ?? 0)
        }
        #expect(joins == 0, "each packet starts where the one before ended")
        #expect(end == 24 * 512 * 1_000_000_000 / 48000, "and the run is as long as its samples")
    }

    @Test(
        "the sample clock keeps its own count near the container's time, and follows it past half a packet"
    )
    func sampleClock() {
        var clock = MediaSampleClock(sampleRate: 48000)
        #expect(clock.place(frames: 512, statedTime: 5_000_000) == (5_000_000, 10_666_667))
        // 333 µs late: within half a packet, so the clock's own time.
        #expect(
            clock.place(frames: 512, statedTime: 15_666_667 + 333_000) == (15_666_667, 10_666_666)
        )
        // A frame missing: more than half a packet off, so the container's time, and a new count from it.
        #expect(clock.place(frames: 512, statedTime: 37_000_000) == (37_000_000, 10_666_667))
        #expect(clock.place(frames: 512, statedTime: 47_666_667) == (47_666_667, 10_666_666))
    }

    @Test(
        "DTS in an AVI, cut every 1 000 bytes: the stream is split back into its frames by their headers"
    )
    func avi() throws {
        let stream = [UInt8](try DTSCoreDecoderTests.fixture("lavc-51-adpcm"))
        var sound = AVITestWriter.Stream()
        sound.type = "auds"
        sound.scale = 1
        // Bytes a second: 2 012 bytes for every 512 samples at 48 kHz, as Lavf's AVI muxer writes it.
        sound.rate = 188_625
        sound.sampleSize = 1
        sound.format = AVITestWriter.audioFormat(
            tag: 0x2001,
            channels: 6,
            rate: 48000,
            bytesPerSecond: 188_625
        )
        sound.chunks = stride(from: 0, to: stream.count, by: 1000).map {
            (Array(stream[$0..<min($0 + 1000, stream.count)]), true)
        }
        let file = try AVIFile(source: DataByteSource(AVITestWriter.file([sound])))
        let first = try file.index().entries(0).first.map(file.read)
        let format = try #require(file.streams[0].sampleFormat(firstFrame: first))
        guard case let .audio(audio) = format else { Issue.record("not sound"); return }
        #expect(audio.isDTS && audio.framesPerPacket == 512 && audio.channels == 6)
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        var decoder = DTSCoreDecoder()
        var times: [Int64] = []
        while let packet = try demuxer.next(track: 0) {
            #expect(packet.data.count == 2012 && packet.frameCount == 512)
            #expect((try decoder.decode(packet.data)).frames == 512)
            times.append(packet.time)
        }
        #expect(times == (0..<24).map { Int64((Double($0 * 2012) / 188_625 * 1e9).rounded()) })
    }

    @Test("a DTS header found in the middle of a stream, borne out by the next one")
    func frameHeader() throws {
        let stream = [UInt8](try DTSCoreDecoderTests.fixture("lavc-51-adpcm"))
        let found = try #require(
            AudioFrameHeader.confirmed(in: Array(stream[300..<6000]), syntax: .dts)
        )
        #expect(found.index == 2012 - 300)
        #expect(found.header.length == 2012 && found.header.samples == 512)
        #expect(found.header.sampleRate == 48000 && found.header.channels == 6)
    }
}
