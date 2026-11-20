import Foundation
import Testing

@testable import DirnexCore

/// Packets out of an AVI: pictures in decoding order with the times they are shown at, and sound cut
/// into frames and timed (PLAN.md §M42 ▸ Slice 5).
@Suite("AVI demuxer")
struct AVIDemuxerTests {
    static let tick: Int64 = 40_000_000

    static func demux(_ streams: [AVITestWriter.Stream]) throws -> AVIDemuxer {
        let file = try AVIFile(source: DataByteSource(AVITestWriter.file(streams)))
        return try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
    }

    static func drain(_ demuxer: inout AVIDemuxer, track: UInt64 = 0) throws -> [MediaPacket] {
        var packets: [MediaPacket] = []
        while let packet = try demuxer.next(track: track) {
            packets.append(packet)
        }
        return packets
    }

    static func video(_ compression: String, _ chunks: [(Data, Bool)]) -> AVITestWriter.Stream {
        var stream = AVITestWriter.Stream()
        stream.format = AVITestWriter.videoFormat(compression: compression)
        stream.chunks = chunks.map { ([UInt8]($0.0), $0.1) }
        return stream
    }

    // MARK: - H.264

    static let sequence = H264TestWriter.Sequence(reorderDepth: 1)

    /// One group: an IDR picture with the parameter sets before it (and an access unit delimiter,
    /// which goes), then P B B, shown I B B P.
    static func group(first: Bool = true) -> [(Data, Bool)] {
        let delimiter = Data([0x09, 0xF0])
        let idr = H264TestWriter.annexB([
            delimiter,
            H264TestWriter.sequence(sequence),
            H264TestWriter.picture(),
            H264TestWriter.slice(sequence, idr: true, type: 2, orderLSB: 0)
        ])
        func slice(_ type: Int, _ lsb: Int, reference: Bool) -> Data {
            H264TestWriter.annexB(
                [
                    H264TestWriter.slice(
                        sequence,
                        reference: reference,
                        type: type,
                        frameNumber: 1,
                        orderLSB: lsb
                    )
                ]
            )
        }
        return [
            (idr, true),
            (slice(0, 6, reference: true), false),
            (slice(1, 2, reference: false), false),
            (slice(1, 4, reference: false), false)
        ]
    }

    @Test(
        "H.264: decoding order out, shown I B B P, start codes turned to lengths, the delimiter gone"
    )
    func h264Order() throws {
        var demuxer = try Self.demux([Self.video("H264", Self.group())])
        let packets = try Self.drain(&demuxer)
        #expect(packets.map { $0.time / Self.tick } == [0, 3, 1, 2])
        #expect(packets.map(\.isKeyframe) == [true, false, false, false])
        #expect(packets.allSatisfy { $0.duration == Self.tick })
        let units = try #require(H264NALUnits.lengthPrefixed(packets[0].data, lengthSize: 4))
        #expect(units.map(H264NALUnits.type) == [7, 8, 5])
    }

    @Test("H.264: a seek starts at the key frame before the target, earlier pictures as preroll")
    func h264Seek() throws {
        var demuxer = try Self.demux([Self.video("H264", Self.group() + Self.group())])
        demuxer.seek(to: 6 * Self.tick)
        let packets = try Self.drain(&demuxer)
        #expect(packets.map { $0.time / Self.tick } == [4, 7, 5, 6])
        #expect(packets.map(\.isPreroll) == [true, false, true, false])
    }

    @Test("H.264: after a seek to an intra picture that is not IDR, the B-frames shown before it go")
    func h264OpenGroup() throws {
        let sequence = Self.sequence
        func slice(_ type: Int, _ lsb: Int, reference: Bool = true) -> Data {
            H264TestWriter.annexB(
                [
                    H264TestWriter.slice(
                        sequence,
                        reference: reference,
                        type: type,
                        frameNumber: 2,
                        orderLSB: lsb
                    )
                ]
            )
        }
        let open: [(Data, Bool)] = [
            (slice(2, 14), true), (slice(1, 10, reference: false), false),
            (slice(1, 12, reference: false), false), (slice(0, 20), false)
        ]
        var demuxer = try Self.demux([Self.video("H264", Self.group() + open)])
        #expect(try Self.drain(&demuxer).count == 8)
        demuxer.seek(to: 6 * Self.tick)
        let packets = try Self.drain(&demuxer)
        #expect(
            packets.map(\.data) == [open[0].0, open[3].0].map { H264NALUnits.lengthPrefixed(
                H264NALUnits.annexB($0)
            ) }
        )
    }

    // MARK: - MPEG-4 Part 2

    static func plane(_ type: Int, coded: Bool = true) -> Data {
        MPEG4VisualTests.plane(type, coded: coded)
    }

    @Test(
        "DivX's packed bitstream: each B-frame comes out of its P-frame's chunk with the next tick"
    )
    func packedBitstream() throws {
        let headers = MPEG4VisualTests.xvidHeaders
        let nothing = Self.plane(1, coded: false)
        var demuxer = try Self.demux([Self.video("DX50", [
            (headers + Self.plane(0), true), (Self.plane(1) + Self.plane(2), false),
            (nothing, false),
            (Self.plane(1) + Self.plane(2), false), (nothing, false), (Self.plane(1), false)
        ])])
        let packets = try Self.drain(&demuxer)
        #expect(packets.map(\.data) == [
            headers + Self.plane(0), Self.plane(1), Self.plane(2), Self.plane(1), Self.plane(2),
            Self.plane(1)
        ])
        #expect(packets.map { $0.time / Self.tick } == [0, 2, 1, 4, 3, 5])
        #expect(packets.map(\.isKeyframe) == [true, false, false, false, false, false])
    }

    @Test("a plane with nothing coded, not after a packed chunk, is a tick with nothing new to show")
    func skippedPlane() throws {
        var demuxer = try Self.demux([Self.video("XVID", [
            (MPEG4VisualTests.xvidHeaders + Self.plane(0), true), (Self.plane(1), false),
            (Self.plane(1, coded: false), false), (Self.plane(1), false)
        ])])
        #expect(try Self.drain(&demuxer).map { $0.time / Self.tick } == [0, 1, 3])
    }

    // MARK: - Motion JPEG

    @Test(
        "Motion JPEG: a frame without tables gets them, and an empty chunk is a tick left to the last"
    )
    func motionJPEG() throws {
        let head = try MPEG4VisualTests.lavcHead()
        let stripped = MPEG4VisualTests.withoutTables(head)
        var demuxer = try Self.demux(
            [Self.video("MJPG", [(stripped, true), (Data(), true), (head, true)])]
        )
        let packets = try Self.drain(&demuxer)
        #expect(packets.map { $0.time / Self.tick } == [0, 2])
        #expect(packets[0].data == MotionJPEG.withStandardTables(stripped))
        #expect(packets[1].data == head)
    }
}

/// Sound out of an AVI: cut into frames however the chunks cut it, and timed by its chunks or its
/// bytes as its header says.
@Suite("AVI demuxer, sound")
struct AVIDemuxerSoundTests {
    static func audio(
        tag: UInt16,
        scale: UInt32,
        rate: UInt32,
        sampleSize: UInt32 = 0,
        blockAlign: Int = 1,
        bits: Int = 16,
        extra: [UInt8] = [],
        chunks: [[UInt8]]
    ) -> AVITestWriter.Stream {
        var stream = AVITestWriter.Stream()
        stream.type = "auds"
        stream.scale = scale
        stream.rate = rate
        stream.sampleSize = sampleSize
        stream.format = AVITestWriter.audioFormat(
            tag: tag,
            blockAlign: blockAlign,
            bits: bits,
            extra: extra
        )
        stream.chunks = chunks.map { ($0, true) }
        return stream
    }

    @Test("a stream stored a frame to a chunk is timed by its chunks, empty ones included")
    func chunkTimed() throws {
        let aac = Self.audio(
            tag: 0xFF,
            scale: 1024,
            rate: 48000,
            extra: [0x11, 0x90],
            chunks: [[1, 1, 1], [], [], [4, 4, 4], [5, 5]]
        )
        var demuxer = try AVIDemuxerTests.demux([aac])
        let packets = try AVIDemuxerTests.drain(&demuxer)
        #expect(packets.map(\.time) == [0, 64_000_000, 85_333_333])
        #expect(packets.map(\.frameCount) == [1024, 1024, 1024])
        #expect(packets.map(\.data) == [Data([1, 1, 1]), Data([4, 4, 4]), Data([5, 5])])
        demuxer.seek(to: 80_000_000)
        #expect(
            try AVIDemuxerTests.drain(&demuxer).map(\.time) == [64_000_000, 85_333_333],
            "64 ms runs past 80"
        )
    }

    /// Seen 2026-11-20 in an AVI made from the 3GP sample's AAC: the first header-like pattern in a raw
    /// frame was taken for ADTS, and the track came out as 169 three-block "frames" for 1 345 chunks.
    @Test("a raw AAC frame holding a pattern like an ADTS header is still one frame to a chunk")
    func rawAACWithAFalseHeader() throws {
        let frame: [UInt8] = [0x21, 0x10, 0x05] + [0xFF, 0xF1, 0x4C, 0x80, 0x2A, 0xA2, 0x54] + [
            UInt8
        ](repeating: 9, count: 40)
        let aac = Self.audio(
            tag: 0xFF,
            scale: 1024,
            rate: 48000,
            extra: [0x11, 0x90],
            chunks: [frame, frame, frame]
        )
        let file = try AVIFile(source: DataByteSource(AVITestWriter.file([aac])))
        guard case let .audio(format)? = file.streams[0].sampleFormat(firstFrame: Data(frame)) else {
            Issue.record("no format")
            return
        }
        #expect(
            format.magicCookie == AACConfiguration.magicCookie(
                audioSpecificConfig: Data([0x11, 0x90])
            )
        )
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        let packets = try AVIDemuxerTests.drain(&demuxer)
        #expect(packets.map(\.data) == Array(repeating: Data(frame), count: 3))
        #expect(packets.map(\.frameCount) == [1024, 1024, 1024])
    }

    @Test("AAC behind ADTS headers: the headers come off, and the configuration comes from them")
    func adts() throws {
        let frame: [UInt8] = [0xFF, 0xF1, 0x4C, 0x80, 0x01, 0x7F, 0xFC, 0xAA, 0xBB, 0xCC, 0xDD]
        let aac = Self.audio(tag: 0xFF, scale: 1024, rate: 48000, chunks: [frame, frame])
        let file = try AVIFile(source: DataByteSource(AVITestWriter.file([aac])))
        guard case let .audio(format)? = file.streams[0].sampleFormat(firstFrame: Data(frame)) else {
            Issue.record("no format")
            return
        }
        #expect(
            format.magicCookie == AACConfiguration.magicCookie(
                audioSpecificConfig: Data([0x11, 0x90])
            )
        )
        var demuxer = try AVIDemuxer(file: file, index: file.index(), streams: file.streams)
        #expect(
            try AVIDemuxerTests.drain(&demuxer).map(\.data) == [
                Data([0xAA, 0xBB, 0xCC, 0xDD]),
                Data([0xAA, 0xBB, 0xCC, 0xDD])
            ]
        )
    }

    @Test(
        "constant-rate MP3 cut every 1000 bytes: each frame timed by its first byte, before and after a seek"
    )
    func byteTimed() throws {
        let frame = AudioFrameHeaderTests.mp3Frame(7)
        let stream = Array(repeating: frame, count: 7).flatMap(\.self)
        let chunks = stride(from: 0, to: stream.count, by: 1000).map { Array(
            stream[$0..<min($0 + 1000, stream.count)]
        ) }
        let mp3 = Self.audio(tag: 0x55, scale: 1, rate: 16000, sampleSize: 1, chunks: chunks)
        var demuxer = try AVIDemuxerTests.demux([mp3])
        let packets = try AVIDemuxerTests.drain(&demuxer)
        #expect(packets.count == 7)
        #expect(
            packets.map(\.time) == (0..<7).map { Int64((Double($0 * 417) / 16000 * 1e9).rounded()) }
        )
        #expect(packets.allSatisfy { $0.data == Data(frame) && $0.frameCount == 1152 })
        demuxer.seek(to: 100_000_000)
        #expect(
            try demuxer.next(track: 0)?.time == 78_187_500,
            "the first frame starting in the chunk sought"
        )
    }

    @Test("PCM: whole frames only, the rest carried into the next chunk, timed by bytes")
    func pcm() throws {
        let pcm = Self.audio(
            tag: 1,
            scale: 1,
            rate: 48000,
            sampleSize: 4,
            blockAlign: 4,
            chunks: [Array(0..<10), Array(10..<20)]
        )
        var demuxer = try AVIDemuxerTests.demux([pcm])
        let packets = try AVIDemuxerTests.drain(&demuxer)
        #expect(packets.map(\.data) == [Data(0..<8), Data(8..<20)])
        #expect(packets.map(\.frameCount) == [2, 3])
        #expect(packets.map(\.time) == [0, Int64((2.0 / 48000 * 1e9).rounded())])
    }

    @Test("the plan plays the first sound that decodes, as an AVI marks no default")
    func plan() throws {
        let wma = Self.audio(tag: 0x161, scale: 1, rate: 16000, chunks: [[1]])
        let mp3 = Self.audio(tag: 0x55, scale: 1152, rate: 48000, chunks: [[1]])
        let file = try AVIFile(
            source: DataByteSource(
                AVITestWriter.file(
                    [AVIDemuxerTests.video("H264", AVIDemuxerTests.group()), wma, mp3]
                )
            )
        )
        let plan = AVIPlaybackPlan(tracks: file.streams) { $0.sampleFormat(firstFrame: nil) != nil }
        #expect(plan.audio?.number == 2)
        #expect(plan.audioTracks.map(\.isDecodable) == [false, true])
        #expect(plan.video == nil && plan.refusesPicture, "no first frame, so no parameter sets")
    }
}
