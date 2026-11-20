import Foundation
import Testing

@testable import DirnexCore

/// Finding compressed sound frames by their headers (PLAN.md §M42 ▸ Slice 5).
@Suite("Audio frame headers")
struct AudioFrameHeaderTests {
    static func header(_ bytes: [UInt8], _ syntax: AudioFrameHeader.Syntax) -> AudioFrameHeader? {
        AudioFrameHeader.parse(bytes + [0, 0, 0], at: 0, syntax: syntax)
    }

    @Test("MPEG audio frame lengths: layer III at 128 kbit/s and 44.1 kHz is 417 bytes, 418 padded")
    func mpegLayerThree() throws {
        let plain = try #require(Self.header([0xFF, 0xFB, 0x90, 0x00], .mpeg))
        #expect(plain.length == 417)
        #expect(plain.samples == 1152)
        #expect(plain.sampleRate == 44100)
        #expect(plain.channels == 2)
        #expect(plain.layer == 3)
        #expect(Self.header([0xFF, 0xFB, 0x92, 0x00], .mpeg)?.length == 418)
        #expect(Self.header([0xFF, 0xFB, 0x90, 0xC0], .mpeg)?.channels == 1)
    }

    @Test("MPEG-2 layer III at 22.05 kHz holds 576 samples; layers II and I have their own sizes")
    func mpegOtherLayers() throws {
        let half = try #require(Self.header([0xFF, 0xF3, 0x80, 0x00], .mpeg))
        #expect(half.sampleRate == 22050)
        #expect(half.samples == 576)
        #expect(half.length == 72 * 64000 / 22050)
        let layerTwo = try #require(Self.header([0xFF, 0xFD, 0xA4, 0x00], .mpeg))
        #expect(layerTwo.layer == 2)
        #expect(layerTwo.length == 576)
        let layerOne = try #require(Self.header([0xFF, 0xFF, 0xC0, 0x00], .mpeg))
        #expect(layerOne.layer == 1)
        #expect(layerOne.samples == 384)
        #expect(layerOne.length == 416)
    }

    @Test("a free-format, a bad rate or a reserved version is no MPEG audio header")
    func mpegRefused() {
        #expect(Self.header([0xFF, 0xFB, 0x00, 0x00], .mpeg) == nil)
        #expect(Self.header([0xFF, 0xFB, 0xF0, 0x00], .mpeg) == nil)
        #expect(Self.header([0xFF, 0xEB, 0x90, 0x00], .mpeg) == nil)
        #expect(Self.header([0xFF, 0xFB, 0x9C, 0x00], .mpeg) == nil)
    }

    /// The lace sizes mkvmerge wrote are the witness: the header's size rule has to land on each.
    @Test("every AC-3 frame in the film's first cluster is as long as its header says")
    func ac3AgainstTheFilm() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "film.mkv"))
        let offset = try #require(file.firstClusterOffset)
        let cluster = try #require(try file.cluster(from: offset))
        var checked = 0
        var channels: [UInt64: Set<Int>] = [:]
        for block in cluster.blocks where [2, 6, 7, 8, 10].contains(block.track) {
            for (index, range) in block.frames.enumerated() {
                let head = try [UInt8](file.frame(index, of: block).prefix(8))
                let header = try #require(AudioFrameHeader.parse(head, at: 0, syntax: .ac3))
                #expect(header.length == range.count)
                #expect(header.sampleRate == 48000)
                channels[block.track, default: []].insert(header.channels)
                checked += 1
            }
        }
        #expect(checked == 5 * 47)
        // Two 3/2 tracks with LFE (448 and 640 kbit/s) and three stereo ones.
        #expect(channels.values.filter { $0 == [6] }.count == 2)
        #expect(channels.values.filter { $0 == [2] }.count == 3)
    }

    @Test("AC-3 at 44.1 kHz adds a word for an odd size code; E-AC-3 is not read as AC-3")
    func ac3Sizes() {
        // 192 kbit/s: 417 words even, 418 odd.
        #expect(Self.header([0x0B, 0x77, 0, 0, 0x54, 0x40, 0x40], .ac3)?.length == 834)
        #expect(Self.header([0x0B, 0x77, 0, 0, 0x55, 0x40, 0x40], .ac3)?.length == 836)
        #expect(Self.header([0x0B, 0x77, 0, 0, 0x14, 0x40, 0x40], .ac3)?.length == 768)
        #expect(Self.header([0x0B, 0x77, 0, 0, 0x14, 0x80, 0x40], .ac3) == nil, "bsid 16")
    }

    @Test("the AVI sample's ADTS header: 341 bytes, seven of them header, AAC LC at 48 kHz stereo")
    func adts() throws {
        let header = try #require(Self.header([0xFF, 0xF1, 0x4C, 0x80, 0x2A, 0xA2, 0x54], .adts))
        #expect(header.length == 341)
        #expect(header.headerLength == 7)
        #expect(header.samples == 1024)
        #expect(header.sampleRate == 48000)
        #expect(header.channels == 2)
        #expect(header.audioSpecificConfig == Data([0x11, 0x90]))
        #expect(Self.header([0xFF, 0xF0, 0x4C, 0x80, 0x2A, 0xA2, 0x54], .adts)?.headerLength == 9)
    }

    // MARK: - Splitting

    /// A layer III frame of 417 bytes, its body filled with `fill`.
    static func mp3Frame(_ fill: UInt8) -> [UInt8] {
        [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: fill, count: 413)
    }

    @Test("frames cut across chunks come out whole, each placed by where it starts")
    func splitAcrossChunks() {
        var splitter = AudioFrameSplitter(syntax: .mpeg)
        let stream = Self.mp3Frame(1) + Self.mp3Frame(2) + Self.mp3Frame(3)
        let first = splitter.append(Data(stream[0..<600]))
        #expect(first.map(\.offset) == [0])
        #expect(!splitter.isEmpty)
        let second = splitter.append(Data(stream[600...]))
        #expect(second.map(\.data) == [Data(Self.mp3Frame(2)), Data(Self.mp3Frame(3))])
        #expect(
            second.map(\.offset) == [417 - 600, 834 - 600],
            "the second began in the first chunk"
        )
        #expect(splitter.isEmpty)
    }

    @Test(
        "bytes before the first frame, and a header-like pattern not followed by a frame, are passed over"
    )
    func resync() {
        var splitter = AudioFrameSplitter(syntax: .mpeg)
        // A false header 10 bytes in: it would end at 427, where no frame starts.
        let garbage: [UInt8] = [7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 0xFF, 0xFB, 0x90, 0x00, 1, 2, 3]
        let frames = splitter.append(Data(garbage + Self.mp3Frame(4) + Self.mp3Frame(5)))
        #expect(frames.map(\.offset) == [garbage.count, garbage.count + 417])
        splitter.reset()
        #expect(splitter.isEmpty)
    }
}
