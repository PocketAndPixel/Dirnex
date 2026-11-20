import Foundation
import Testing

@testable import DirnexCore

/// An AVI's headers and its index, by every route a writer leaves (PLAN.md §M42 ▸ Slice 5).
///
/// Every chunk carries bytes of its own, so an entry is checked by what reading it gives back rather
/// than by an offset computed the way the reader computes it.
@Suite("AVI file")
struct AVIFileTests {
    /// A picture stream of `count` chunks, a key frame every `keyEvery`, and a sound stream of as
    /// many, each chunk's bytes naming its stream and number. Sound chunks are odd-sized, so the pad
    /// byte RIFF adds after them is in play.
    static func streams(count: Int = 6, keyEvery: Int = 3) -> [AVITestWriter.Stream] {
        var video = AVITestWriter.Stream()
        video.format = AVITestWriter.videoFormat(width: 640, height: 360, compression: "XVID")
        video.handler = "xvid"
        video.name = "Picture"
        video.chunks = (0..<count).map { ([0xA0, UInt8($0), 1, 2], $0 % keyEvery == 0) }
        var audio = AVITestWriter.Stream()
        audio.type = "auds"
        audio.handler = "\0\0\0\0"
        audio.scale = 1152
        audio.rate = 44100
        audio.format = AVITestWriter.audioFormat(
            tag: 0x55,
            rate: 44100,
            bytesPerSecond: 16000,
            blockAlign: 1152
        )
        audio.chunks = (0..<count).map { ([0xB0, UInt8($0), 9], false) }
        return [video, audio]
    }

    static func open(_ data: Data) throws -> AVIFile {
        try AVIFile(source: DataByteSource(data))
    }

    /// What each entry of each stream reads back as.
    static func contents(_ file: AVIFile, _ index: AVIIndex) throws -> [[[UInt8]]] {
        try index.streams.map { entries in try entries.map { try [UInt8](file.read($0)) } }
    }

    @Test("the headers: each stream's kind, clock, format and name")
    func headers() throws {
        let file = try Self.open(AVITestWriter.file(Self.streams()))
        #expect(file.header.streamCount == 2)
        #expect(file.header.totalFrames == 6)
        #expect(file.streams.count == 2)
        let video = file.streams[0]
        #expect(video.kind == .video)
        #expect(video.handler == "xvid")
        #expect(video.video?.compression == "XVID")
        #expect(video.video?.width == 640 && video.video?.height == 360)
        #expect(video.name == "Picture")
        #expect(video.durationSeconds == 6.0 / 25)
        #expect(video.isEnabled)
        let audio = file.streams[1]
        #expect(audio.kind == .audio)
        #expect(audio.number == 1)
        #expect(audio.audio?.formatTag == 0x55)
        #expect(audio.audio?.sampleRate == 44100)
        #expect(audio.audio?.blockAlign == 1152)
        #expect(file.durationSeconds == 6.0 / 25, "the picture's length, not the sound's")
        #expect(file.movieLists.count == 1)
    }

    @Test("WAVE_FORMAT_EXTENSIBLE is read as the tag in its subformat; a disabled stream says so")
    func extensibleAndDisabled() throws {
        var streams = Self.streams()
        // Valid bits, a channel mask, then the subformat GUID, whose first two bytes are the tag.
        let extensible = [16, 0, 3, 0, 0, 0, 1, 0] + [UInt8](repeating: 0, count: 14)
        streams[1].format = AVITestWriter.audioFormat(tag: 0xFFFE, blockAlign: 4, extra: extensible)
        streams[1].flags = 1
        let file = try Self.open(AVITestWriter.file(streams))
        #expect(file.streams[1].audio?.formatTag == 1)
        #expect(file.streams[1].extraData.count == 22)
        #expect(!file.streams[1].isEnabled)
    }

    @Test("a RIFF that is no AVI, or no RIFF at all, is refused")
    func notAVI() {
        let wave = Data("RIFF".utf8) + Data([4, 0, 0, 0]) + Data("WAVE".utf8)
        #expect(throws: AVIError.notAVI) { try Self.open(wave) }
        #expect(throws: AVIError.notAVI) { try Self.open(Data([1, 2, 3])) }
    }

    @Test(
        "idx1 counted from the movi list: every chunk found, key frames marked, sound always a key"
    )
    func legacyIndex() throws {
        let file = try Self.open(AVITestWriter.file(Self.streams()))
        let index = try file.index()
        #expect(index.origin == .legacy)
        #expect(try Self.contents(file, index) == [
            (0..<6).map { [0xA0, UInt8($0), 1, 2] },
            (0..<6).map { [0xB0, UInt8($0), 9] }
        ])
        #expect(index.streams[0].map(\.isKeyframe) == [true, false, false, true, false, false])
        #expect(index.streams[1].allSatisfy { $0.isKeyframe })
    }

    @Test("idx1 counted from the start of the file, as a few writers count it")
    func legacyIndexFromFileStart() throws {
        let file = try Self.open(
            AVITestWriter.file(Self.streams(), index: .legacy(fromFileStart: true))
        )
        let index = try file.index()
        #expect(index.origin == .legacy)
        #expect(try Self.contents(file, index)[1].last == [0xB0, 5, 9])
    }

    @Test("OpenDML: the chunks of both RIFFs, from each stream's standard indexes")
    func openDML() throws {
        let file = try Self.open(AVITestWriter.file(Self.streams(), index: .openDML(split: 4)))
        #expect(file.movieLists.count == 2)
        #expect(file.totalFrames == 6)
        let index = try file.index()
        #expect(index.origin == .openDML)
        #expect(try Self.contents(file, index) == [
            (0..<6).map { [0xA0, UInt8($0), 1, 2] },
            (0..<6).map { [0xB0, UInt8($0), 9] }
        ])
        #expect(index.streams[0].map(\.isKeyframe) == [true, false, false, true, false, false])
    }

    @Test(
        "no index: the movi list is walked, rec lists and all, and an H.264 key frame told by its slice"
    )
    func walk() throws {
        var streams = Self.streams()
        streams[0].format = AVITestWriter.videoFormat(compression: "H264")
        let idr: [UInt8] = [0, 0, 0, 1, 0x65, 0x88]
        let other: [UInt8] = [0, 0, 0, 1, 0x41, 0x9A]
        streams[0].chunks = [(idr, true), (other, false), (other, false), (idr, true)]
        let file = try Self.open(AVITestWriter.file(streams, index: .none, records: true))
        let index = try file.index()
        #expect(index.origin == .walk)
        #expect(index.streams[0].map(\.isKeyframe) == [true, false, false, true])
        #expect(index.streams[1].count == 6)
        #expect(try Self.contents(file, index)[1][5] == [0xB0, 5, 9])
    }

    @Test("an idx1 whose offsets lead nowhere is passed over for the walk")
    func brokenLegacyIndex() throws {
        var data = [UInt8](AVITestWriter.file(Self.streams()))
        let found = try #require(
            data.indices.dropLast(4).last { Array(data[$0..<$0 + 4]) == Array("idx1".utf8) }
        )
        // Every entry's offset pushed far past the file.
        for entry in stride(from: found + 8, to: data.count, by: 16) {
            data[entry + 11] = 0x7F
        }
        let file = try Self.open(Data(data))
        let index = try file.index()
        #expect(index.origin == .walk)
        #expect(index.streams[0].count == 6)
    }

    @Test("a movi list whose size was never filled in runs to the end of the file")
    func unfinishedMovieList() throws {
        var data = [UInt8](AVITestWriter.file(Self.streams(), index: .none))
        let movi = try #require(
            data.indices.dropLast(4).first { Array(data[$0..<$0 + 4]) == Array("movi".utf8) }
        )
        data.replaceSubrange(movi - 4..<movi, with: [0, 0, 0, 0])
        let file = try Self.open(Data(data))
        let index = try file.index()
        #expect(index.streams.map(\.count) == [6, 6])
    }

    @Test("what the card says: the picture's size and the codecs, by code and tag")
    func summary() throws {
        let file = try Self.open(AVITestWriter.file(Self.streams()))
        #expect(MediaSummary(avi: file).facts == "640×360 · MPEG-4 · MP3")
        #expect(MediaCodecName.name(windowsVideoCode: "\0\0\0\0") == "Uncompressed")
        #expect(MediaCodecName.name(windowsVideoCode: "div3") == "MPEG-4 v3")
        #expect(MediaCodecName.name(windowsVideoCode: "ABCD") == "ABCD")
        #expect(MediaCodecName.name(windowsAudioTag: 0x2000) == "AC-3")
        #expect(MediaCodecName.name(windowsAudioTag: 0x1234) == "0x1234")
    }
}
