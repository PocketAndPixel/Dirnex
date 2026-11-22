import Foundation
import Testing

@testable import DirnexCore

/// How long a packet of Opus or Vorbis is, and what a VP9 key frame says of its stream (PLAN.md §M42 ▸
/// Slice 4).
@Suite("Media packet lengths and VP9 headers")
struct MediaPacketFramesTests {
    @Test(
        "an Opus packet's length from its table of contents",
        arguments: [
            // CELT 20 ms, one frame: the Steam clip's packets.
            ([0xFC, 0xFF, 0xFE], 960),
            // CELT 10 ms: libwebm's.
            ([0xF4], 480),
            // SILK 60 ms, two frames of equal size.
            ([0x19], 5760),
            // Hybrid 10 ms, two frames of different sizes.
            ([0x62], 960),
            // CELT 2.5 ms, code 3 with six frames.
            ([0x83, 0x06], 720),
            // SILK 60 ms, code 3 with three frames: 180 ms, past the RFC's 120.
            ([0x1B, 0x03], nil),
            // Code 3 with no count byte.
            ([0x83], nil),
            ([], nil)
        ] as [([UInt8], Int?)]
    )
    func opus(_ packet: [UInt8], _ frames: Int?) {
        #expect(OpusPacket.frames(Data(packet)) == frames)
    }

    @Test("libwebm's Opus packets are 10 ms each, as its 2.13 s first cluster of 213 says")
    func libwebmOpus() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "libwebm-opus.webm"))
        let opus = try #require(file.track(number: 2))
        let counter = try #require(MediaFrameCounter(opus))
        var demuxer = MatroskaDemuxer(file: file, tracks: [opus])
        let first = try #require(try demuxer.next(track: 2))
        #expect(counter.frames(in: first.data, previousBlock: nil)?.frames == 480)
        #expect(first.frameCount == 480)
        #expect(first.duration == 10_000_000)
    }

    @Test("Vorbis's modes are found from the end of the setup header")
    func vorbisModes() throws {
        let headers = try #require(
            VorbisHeaders(
                identification: Self.identification,
                setup: Self.setup(modes: [false, true])
            )
        )
        #expect(headers.blockSizes == (256, 2048))
        #expect(headers.modeIsLong == [false, true])
        let three = try #require(
            VorbisHeaders(
                identification: Self.identification,
                setup: Self.setup(modes: [false, true, true])
            )
        )
        #expect(three.modeIsLong == [false, true, true])
    }

    @Test("a Vorbis packet lasts a quarter of its block and a quarter of the block before")
    func vorbisFrames() throws {
        let headers = try #require(
            VorbisHeaders(
                identification: Self.identification,
                setup: Self.setup(modes: [false, true])
            )
        )
        // Bit 0 is the packet type (0 for audio), bit 1 the mode (one bit for two modes), and for a
        // long block bit 2 says whether the window before it was long.
        let short = Data([0b000])
        let longAfterLong = Data([0b110])
        let longAfterShort = Data([0b010])
        #expect(headers.frames(in: short, previousBlock: nil)! == (128, 256))
        #expect(headers.frames(in: short, previousBlock: 2048)! == (576, 256))
        #expect(headers.frames(in: longAfterLong, previousBlock: nil)! == (1024, 2048))
        #expect(headers.frames(in: longAfterShort, previousBlock: 2048)! == (576, 2048))
        #expect(headers.frames(in: Data([0b001]), previousBlock: nil) == nil, "a header packet")
        #expect(VorbisHeaders.integerLog(0) == 0)
        #expect(VorbisHeaders.integerLog(1) == 1)
        #expect(VorbisHeaders.integerLog(3) == 2)
        #expect(VorbisHeaders.integerLog(4) == 3)
    }

    @Test("with one mode no bit names it, and a long block's previous window is the next bit")
    func vorbisOneMode() throws {
        let headers = try #require(
            VorbisHeaders(identification: Self.identification, setup: Self.setup(modes: [true]))
        )
        #expect(headers.frames(in: Data([0b10]), previousBlock: nil)! == (1024, 2048))
        #expect(headers.frames(in: Data([0b00]), previousBlock: nil)! == (576, 2048))
    }

    @Test("the Prism WebM's Vorbis headers, as the file carries them")
    func prismVorbis() throws {
        let url = try #require(Bundle.module.url(
            forResource: "prism-vorbis",
            withExtension: "private",
            subdirectory: "Fixtures/Matroska"
        ))
        let headers = try #require(VorbisHeaders(codecPrivate: try Data(contentsOf: url)))
        // Both of Prism's block sizes are 2048 (identification byte 28 is 0xBB), so every packet is
        // 1024 frames, as AudioToolbox's own Ogg reader counted them.
        #expect(headers.blockSizes == (2048, 2048))
        #expect(headers.frames(in: Data([0]), previousBlock: 2048)?.frames == 1024)
        #expect(VorbisHeaders.unlace(try Data(contentsOf: url))?.map(\.count) == [30, 16, 3242])
    }

    @Test("a key frame's header gives profile, depth, colour space and chroma")
    func vp9Header() throws {
        // The Steam clip's first frame: profile 0, a key frame, colour space unknown, 4:2:0.
        let steam = try #require(
            VP9FrameHeader(Data([0x82, 0x49, 0x83, 0x42, 0x00, 0x1C, 0x10, 0x1C]))
        )
        #expect(
            steam.profile == 0 && steam.bitDepth == 8 && steam.colorSpace == 0 && !steam.isFullRange
        )
        #expect(steam.subsamplingX && steam.subsamplingY)
        #expect(
            steam.configurationRecord(width: 450, height: 450) == Data(
                [1, 0, 0, 0, 0, 21, 0x80, 2, 2, 2, 0, 0]
            )
        )

        // Profile 2: marker 10, profile bits 0 then 1, then a key frame; 12 bits, BT.709, full range.
        var bits = BitWriter()
        bits.write(0b10, 2); bits.write(0, 1); bits.write(1, 1)
        bits.write(0, 1); bits.write(0, 1); bits.write(1, 1); bits.write(0, 1)
        bits.write(0x49_8342, 24)
        bits.write(1, 1); bits.write(2, 3); bits.write(1, 1)
        let deep = try #require(VP9FrameHeader(bits.data))
        #expect(deep.profile == 2 && deep.bitDepth == 12 && deep.colorSpace == 2 && deep.isFullRange)
        #expect(
            deep.configurationRecord(width: 3840, height: 2160)[4...9] == Data(
                [2, 50, 12 << 4 | 1, 1, 1, 1]
            )
        )

        // Profile 1, 4:4:4.
        var four = BitWriter()
        four.write(0b10, 2); four.write(1, 1); four.write(0, 1)
        four.write(0, 1); four.write(0, 1); four.write(1, 1); four.write(0, 1)
        four.write(0x49_8342, 24)
        four.write(1, 3); four.write(0, 1); four.write(0, 1); four.write(0, 1); four.write(0, 1)
        let full = try #require(VP9FrameHeader(four.data))
        #expect(full.profile == 1 && !full.subsamplingX && !full.subsamplingY)
        #expect(full.configurationRecord(width: 64, height: 64)[6] == 8 << 4 | 3 << 1)
    }

    @Test("an inter frame, a repeated frame and bytes that are no VP9 have no header to read")
    func vp9Refusals() {
        #expect(VP9FrameHeader(Data([0x86, 0x49, 0x83, 0x42, 0, 0])) == nil, "frame_type 1")
        #expect(VP9FrameHeader(Data([0x88, 0x49, 0x83, 0x42, 0, 0])) == nil, "show_existing_frame")
        #expect(VP9FrameHeader(Data([0x82, 0x49, 0x83, 0x43, 0, 0])) == nil, "no sync code")
        #expect(VP9FrameHeader(Data([0x42, 0x49, 0x83, 0x42, 0, 0])) == nil, "no frame marker")
        #expect(VP9FrameHeader(Data([0x82, 0x49, 0x83])) == nil, "cut short")
        #expect(VP9FrameHeader.level(width: 3840, height: 2160) == 50)
        #expect(VP9FrameHeader.level(width: 8192, height: 4352) == 60)
    }

    /// A Vorbis identification header: 48 kHz stereo, short blocks of 256 and long ones of 2048.
    static let identification: Data = {
        var bytes: [UInt8] = [1] + Array("vorbis".utf8) + [0, 0, 0, 0, 2, 0x80, 0xBB, 0, 0]
        bytes += Array(repeating: 0, count: 12)
        bytes += [0xB8, 1]
        return Data(bytes)
    }()

    /// The tail of a setup header for `modes`, after bytes standing in for the codebooks, floors and
    /// residues: the 6-bit mode count less one, each mode's block flag, window and transform types (0)
    /// and mapping, then the framing bit, packed least significant bit first as Vorbis packs them.
    static func setup(modes: [Bool]) -> Data {
        var bits = LSBBitWriter()
        for byte in [UInt8](repeating: 0xA5, count: 40) { bits.write(Int(byte), 8) }
        bits.write(modes.count - 1, 6)
        for (index, isLong) in modes.enumerated() {
            bits.write(isLong ? 1 : 0, 1)
            bits.write(0, 16)
            bits.write(0, 16)
            bits.write(index % 2, 8)
        }
        bits.write(1, 1)
        return Data([5] + Array("vorbis".utf8)) + bits.data
    }
}

/// Writes bits most significant first, as VP9 reads them.
private struct BitWriter {
    private var bytes: [UInt8] = []
    private var count = 0

    mutating func write(_ value: Int, _ width: Int) {
        for shift in stride(from: width - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> shift) & 1) << (7 - count % 8)
            count += 1
        }
    }

    var data: Data { Data(bytes + [0, 0]) }
}

/// Writes bits least significant first within each field and each byte, as Vorbis packs them.
private struct LSBBitWriter {
    private var bytes: [UInt8] = []
    private var count = 0

    mutating func write(_ value: Int, _ width: Int) {
        for shift in 0..<width {
            if count % 8 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= UInt8((value >> shift) & 1) << (count % 8)
            count += 1
        }
    }

    var data: Data { Data(bytes) }
}
