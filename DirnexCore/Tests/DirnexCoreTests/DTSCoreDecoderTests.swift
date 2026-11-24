import Foundation
import Testing

@testable import DirnexCore

/// The DTS core decoder (PLAN.md §M42 ▸ DTS) against sound whose answer is known: test tones that
/// libavcodec's DTS encoder wrote (FFmpeg 9.1), so a decode has to give back the tones' own frequencies
/// and levels, which no decoder controls. FFmpeg's own decoder gave back the same, 102 to 120 dB apart
/// from this one (2026-11-24).
///
/// - `lavc-stereo.dts`: `ffmpeg -f lavfi -i "aevalsrc=0.25*sin(2*PI*440*t)+0.1*sin(2*PI*21300*t)|
///   0.2*sin(2*PI*660*t)+0.1*sin(2*PI*19200*t):s=48000:d=0.25:c=stereo" -c:a dca -strict -2 -b:a 768k`.
///   Huffman, block and plain codes, and the top of the filter bank.
/// - `lavc-51-adpcm.dts`: the same for 5.1(side) at 1 509 kbit/s with `-dca_adpcm 1`: 440, 660 and 880 Hz
///   at 0.25, 0.2 and 0.3 on L, R and C, 50 Hz at 0.25 in the LFE, and 1.1 and 1.32 kHz at 0.15 and 0.1
///   on Ls and Rs. 23 of its 24 frames use prediction.
@Suite("DTS core decoder")
struct DTSCoreDecoderTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "dts", subdirectory: "Fixtures/DTS")
        )
        return try Data(contentsOf: url)
    }

    /// A raw stream's frames, cut where each header says it ends.
    static func frames(_ stream: Data) throws -> [Data] {
        var frames: [Data] = []
        var offset = stream.startIndex
        while offset < stream.endIndex {
            let header = try #require(DTSCoreHeader(stream[offset...]))
            frames.append(stream[offset..<min(stream.endIndex, offset + header.frameSize)])
            offset += header.frameSize
        }
        return frames
    }

    /// Every frame of a fixture through one decoder: the first frame's facts and all the samples.
    static func decode(_ name: String) throws -> (first: DTSDecodedFrame, samples: [Float]) {
        var decoder = DTSCoreDecoder()
        var decoded: [DTSDecodedFrame] = []
        for frame in try frames(fixture(name)) { decoded.append(try decoder.decode(frame)) }
        return (try #require(decoded.first), decoded.flatMap(\.samples))
    }

    /// The level of the tone at `frequency` in channel `channel` of `samples`, measured over 8 192
    /// samples from the 2 048th, past the filters' start: a Hann-windowed projection on the frequency
    /// itself, which a tone at any other frequency here leaks into by less than 10^-5.
    static func level(_ samples: [Float], channels: Int, channel: Int, frequency: Double) -> Double {
        var real = 0.0, imaginary = 0.0, weights = 0.0
        for index in 0..<8192 {
            let window = 0.5 - 0.5 * cos(2 * .pi * Double(index) / 8191)
            let value = Double(samples[(2048 + index) * channels + channel]) * window
            let phase = 2 * .pi * frequency * Double(index) / 48000
            real += value * cos(phase)
            imaginary += value * sin(phase)
            weights += window
        }
        return 2 * (real * real + imaginary * imaginary).squareRoot() / weights
    }

    @Test("stereo: each tone back at its level, the two near the top of the band included")
    func stereoTones() throws {
        let (first, samples) = try Self.decode("lavc-stereo")
        #expect(first.header.audioMode == 2 && first.header.lfeInterpolation == nil)
        #expect(first.layout.tag == 101 << 16 | 2, "Stereo")
        #expect(samples.count == 24 * 512 * 2)
        let level = { (channel: Int, frequency: Double) in
            Self.level(samples, channels: 2, channel: channel, frequency: frequency)
        }
        #expect(abs(level(0, 440) - 0.25) < 0.0005)
        #expect(abs(level(0, 21300) - 0.1) < 0.001)
        #expect(abs(level(1, 660) - 0.2) < 0.0005)
        #expect(abs(level(1, 19200) - 0.1) < 0.001)
        #expect(level(0, 660) < 0.0001 && level(1, 440) < 0.0001, "no tone on the wrong side")
    }

    @Test("5.1 with prediction: every channel's tone in its place and at its level")
    func surroundWithPrediction() throws {
        let (first, samples) = try Self.decode("lavc-51-adpcm")
        #expect(first.header.audioMode == 9)
        #expect(first.header.lfeInterpolation == 64)
        #expect(first.header.samples == 512 && first.header.sampleRate == 48000)
        #expect(first.layout.sources == [1, 2, 0, nil, 3, 4], "L R C LFE Ls Rs from C L R SL SR")
        #expect(first.layout.tag == 121 << 16 | 6, "MPEG_5_1_A")
        let tones: [(Double, Double)] = [
            (440, 0.25),
            (660, 0.2),
            (880, 0.3),
            (50, 0.19986),
            (1100, 0.15),
            (1320, 0.1)
        ]
        for (channel, (frequency, expected)) in tones.enumerated() {
            let found = Self.level(samples, channels: 6, channel: channel, frequency: frequency)
            // The LFE comes back at 0.2 for 0.25 from FFmpeg's decoder too: the encoder's doing.
            #expect(
                abs(found - expected) < 0.0005,
                "channel \(channel) at \(frequency) Hz: \(found)"
            )
            for other in tones.indices where other != channel && tones[other].0 > 100 {
                #expect(
                    Self.level(samples, channels: 6, channel: channel, frequency: tones[other].0) < 0.0001,
                    "channel \(channel) holds \(tones[other].0) Hz"
                )
            }
        }
    }

    @Test("the 5.1 fixture is the one that exercises prediction: without the code book it fails")
    func predictionNeedsItsTable() throws {
        var predicted = 0
        for frame in try Self.frames(Self.fixture("lavc-51-adpcm")) {
            var reader = DTSBitReader(try #require(DTSCoreFrame(frame)).bytes)
            let header = try DTSCoreHeader.read(&reader)
            let audio = try DTSAudioHeader.read(&reader, header: header, channels: 5)
            let info = try DTSSideInfo.read(&reader, header: header, audio: audio)
            if info.prediction.contains(where: { $0.contains { $0 != nil } }) { predicted += 1 }
        }
        #expect(predicted == 23)
        var bare = DTSCoreDecoder(vectors: nil)
        let frames = try Self.frames(Self.fixture("lavc-51-adpcm"))
        #expect(throws: DTSError.unsupported("ADPCM prediction")) {
            for frame in frames { _ = try bare.decode(frame) }
        }
        var stereo = DTSCoreDecoder(vectors: nil)
        for frame in try Self.frames(Self.fixture("lavc-stereo")) { _ = try stereo.decode(frame) }
    }

    @Test("the four ways DTS is stored decode alike: 16-bit and 14-bit words, either byte order")
    func storageForms() throws {
        let frame = try #require(try Self.frames(Self.fixture("lavc-stereo")).first)
        var reference = DTSCoreDecoder()
        let expected = try reference.decode(frame)
        let forms = [
            Self.littleEndian(frame), Self.fourteenBit(frame, littleEndian: false),
            Self.fourteenBit(frame, littleEndian: true)
        ]
        #expect(
            forms.map { [UInt8]($0.prefix(4)) } == [
                [0xFE, 0x7F, 0x01, 0x80],
                [0x1F, 0xFF, 0xE8, 0x00],
                [0xFF, 0x1F, 0x00, 0xE8]
            ]
        )
        for form in forms {
            var decoder = DTSCoreDecoder()
            #expect(try decoder.decode(form) == expected)
        }
    }

    /// `frame`'s 16-bit words with their bytes swapped.
    static func littleEndian(_ frame: Data) -> Data {
        var bytes = [UInt8](frame)
        if bytes.count % 2 == 1 { bytes.append(0) }
        for index in stride(from: 0, to: bytes.count, by: 2) { bytes.swapAt(index, index + 1) }
        return Data(bytes)
    }

    /// `frame`'s bits 14 to a 16-bit word, each word's top two bits copying its sign bit, as DTS on CD
    /// writes them.
    static func fourteenBit(_ frame: Data, littleEndian: Bool) -> Data {
        var bits: [UInt8] = []
        for byte in frame { for shift in (0..<8).reversed() { bits.append(byte >> UInt8(shift) & 1) } }
        while bits.count % 14 != 0 { bits.append(0) }
        var out: [UInt8] = []
        for start in stride(from: 0, to: bits.count, by: 14) {
            var word = bits[start..<start + 14].reduce(UInt16(0)) { $0 << 1 | UInt16($1) }
            if word & 0x2000 != 0 { word |= 0xC000 }
            out += littleEndian ? [UInt8(word & 0xFF), UInt8(word >> 8)] : [
                UInt8(word >> 8),
                UInt8(word & 0xFF)
            ]
        }
        return Data(out)
    }

    @Test("the code books: every one a complete prefix code, and the two rows V1.6.1 misprints")
    func huffmanBooks() throws {
        let all = DTSTables.huffman.merging(DTSTables.huffman129) { first, _ in first }
        #expect(all.count == 62)
        for (name, triples) in all {
            var kraft = 0.0
            var levels = Set<Int32>()
            for start in stride(from: 0, to: triples.count, by: 3) {
                levels.insert(triples[start])
                kraft += pow(2, -Double(triples[start + 1]))
            }
            #expect(kraft == 1, "\(name)")
            #expect(levels.count == triples.count / 3, "\(name) holds a level twice")
        }
        func row(_ book: String, _ level: Int32) -> [Int32]? {
            let triples = all[book] ?? []
            return stride(from: 0, to: triples.count, by: 3).first { triples[$0] == level }.map {
                Array(triples[$0 + 1...$0 + 2])
            }
        }
        // V1.6.1's D65 stops at ±30, and its D129 prints -37 as "37"; V1.2.1 prints these.
        #expect(row("D65", 31) == [15, 28851] && row("D65", -32) == [15, 28848])
        #expect(row("D129", 37) == [11, 1582] && row("D129", -37) == [11, 1581])
    }

    @Test("the vector code books: their sizes, and the one entry the specification prints")
    func vectorTables() {
        let tables = DTSVectorTables.standard
        #expect(tables.prediction.count == 4096 * 4)
        #expect(tables.highFrequency.count == 1024 * 32)
        // D.10.1: "the first entry in the table gives 9928".
        #expect(tables.prediction.first == 9928)
    }

    @Test("every audio mode a core frame carries has a layout, each primary channel once")
    func layouts() throws {
        let counts = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5]
        for mode in 0..<10 {
            for hasLFE in [false, true] {
                let layout = try #require(DTSChannelLayout(audioMode: mode, hasLFE: hasLFE))
                #expect(Int(layout.tag & 0xFFFF) == layout.channels, "mode \(mode)")
                #expect(layout.sources.filter { $0 == nil }.count == (hasLFE ? 1 : 0))
                let primaries = layout.sources.compactMap(\.self)
                #expect(Set(primaries) == Set(0..<counts[mode]), "mode \(mode)")
            }
        }
        #expect(DTSChannelLayout(audioMode: 10, hasLFE: false) == nil)
    }

    @Test("what is not a DTS frame, or is cut short, fails rather than plays")
    func failures() throws {
        var decoder = DTSCoreDecoder()
        #expect(throws: DTSError.notDTS) { try decoder.decode(Data(repeating: 0, count: 2048)) }
        let frame = try #require(try Self.frames(Self.fixture("lavc-stereo")).first)
        #expect(throws: DTSError.truncated) { try decoder.decode(frame.prefix(300)) }
        #expect(DTSCoreHeader(frame.prefix(8)) == nil)
    }
}

/// Where the film is, apart from its suite, whose trait cannot name the suite itself.
enum DTSFilm {
    static let path = NSHomeDirectory() + "/Movies/Treasure Planet.2002.BDRip.1080.mkv"
}

/// The decoder against the film on this Mac (PLAN.md §M42 ▸ DTS), whose four DTS tracks use what the
/// fixtures cannot: libavcodec's encoder writes no high-frequency VQ, and the film codes its top four
/// subbands with it in every frame. Runs only where the film is; nothing of it is in the repository.
///
/// The numbers are FFmpeg 9.1's decode of the same 200 frames (`ffmpeg -i … -f f32le`), 2026-11-24: its
/// RMS per channel, and the levels at 21.5 and 23.5 kHz, inside the VQ subbands. This decoder gave the
/// same to six digits and within 3 %; with the VQ subbands left silent those levels fell by about 75 dB.
@Suite(
    "DTS core decoder, the film",
    .enabled(if: FileManager.default.fileExists(atPath: DTSFilm.path), "needs the film on this Mac")
)
struct DTSFilmTests {
    static let path = DTSFilm.path

    /// 200 frames of a track, decoded, with how many predicted and how many used VQ.
    struct Decoded {
        var samples: [Float] = []
        var predicted = 0
        var vector = 0
    }

    /// 200 frames of `track` from 70 minutes in.
    static func decode(track number: UInt64) throws -> Decoded {
        let file = try MatroskaFile(source: FileByteSource(url: URL(fileURLWithPath: path)))
        var demuxer = MatroskaDemuxer(file: file, tracks: [try #require(file.track(number: number))])
        // By the picture's cues, as the player seeks: without a key track the demuxer walks the clusters.
        try demuxer.seek(to: 4200 * 1_000_000_000, keyTrack: 1)
        var decoder = DTSCoreDecoder()
        var decoded = Decoded()
        for _ in 0..<200 {
            let packet = try #require(try demuxer.next(track: number))
            decoded.samples += try decoder.decode(packet.data).samples
            var reader = DTSBitReader(try #require(DTSCoreFrame(packet.data)).bytes)
            let header = try DTSCoreHeader.read(&reader)
            let audio = try DTSAudioHeader.read(&reader, header: header, channels: 5)
            let info = try DTSSideInfo.read(&reader, header: header, audio: audio)
            if info.prediction.contains(where: { $0.contains { $0 != nil } }) { decoded.predicted += 1 }
            if zip(audio.vqStart, audio.subbands).contains(where: { $0 < $1 }) { decoded.vector += 1 }
        }
        return decoded
    }

    @Test("all four DTS tracks decode, every frame predicting and coding its top subbands by VQ")
    func allTracks() throws {
        for track: UInt64 in [3, 4, 5, 9] {
            let decoded = try Self.decode(track: track)
            #expect(decoded.samples.count == 200 * 512 * 6)
            #expect(decoded.predicted > 150 && decoded.vector == 200, "track \(track)")
        }
    }

    @Test("through the decoding demuxer, the film's 2 000 first packets of DTS join end to end")
    func joins() throws {
        let file = try MatroskaFile(source: FileByteSource(url: URL(fileURLWithPath: Self.path)))
        let track = try #require(file.track(number: 9))
        let first = try #require(try file.firstKeyframe(track: 9))
        let format = try #require(MediaSampleFormat.Audio.decodedDTS(firstFrame: first))
        var plain = MatroskaDemuxer(file: file, tracks: [track])
        var decoding = DTSDecodingDemuxer(
            MatroskaDemuxer(file: file, tracks: [track]),
            decoding: [9: format]
        )
        var statedEnd: Int64?, end: Int64?
        var statedJoins = 0, joins = 0
        for _ in 0..<2000 {
            let stated = try #require(try plain.next(track: 9))
            let packet = try #require(try decoding.next(track: 9))
            if let statedEnd, stated.time != statedEnd { statedJoins += 1 }
            if let end, packet.time != end { joins += 1 }
            statedEnd = stated.time + (stated.duration ?? 0)
            end = packet.time + (packet.duration ?? 0)
        }
        #expect(statedJoins > 200, "the container's own times are off at most block joins")
        #expect(joins == 0)
    }

    @Test("the English original matches FFmpeg's decode, the VQ subbands included")
    func againstFFmpeg() throws {
        let samples = try Self.decode(track: 9).samples
        let rms = (0..<6).map { channel in
            (
                stride(from: channel, to: samples.count, by: 6).reduce(0.0) { $0 + Double(
                    samples[$1] * samples[$1]
                ) }
                    / Double(samples.count / 6)
            ).squareRoot()
        }
        for (found, expected) in zip(
            rms,
            [0.003440, 0.002265, 0.004577, 0.000099, 0.001620, 0.000886]
        ) {
            #expect(abs(found - expected) <= expected * 0.002 + 1e-6, "\(rms)")
        }
        // Channel, frequency, FFmpeg's level: C at 21.5 and 23.5 kHz, L at 23.5.
        let vq: [[Double]] = [[2, 21500, 1.4543e-6], [2, 23500, 1.6152e-6], [0, 23500, 1.1215e-6]]
        for tone in vq {
            let channel = Int(tone[0]), frequency = tone[1], expected = tone[2]
            let found = DTSCoreDecoderTests.level(
                samples,
                channels: 6,
                channel: channel,
                frequency: frequency
            )
            #expect(
                abs(found - expected) < expected * 0.1,
                "channel \(channel) at \(frequency) Hz: \(found)"
            )
        }
    }
}
