import Foundation
import Testing

@testable import DirnexCore

/// Opening a Matroska or WebM file as far as its tracks (PLAN.md §M42 ▸ Slice 3), over files built
/// here for the shapes no muxer on this Mac was found writing. `MatroskaCapturedTests` holds the reader
/// to real files.
@Suite("Matroska head")
struct MatroskaFileTests {
    @Test("a file names its container, its clock and length, and its tracks")
    func head() throws {
        let file = try MatroskaFile(source: MKV.file(docType: "webm", [
            MKV.info(scale: 1_000_000, duration: 53781, title: "Sample"),
            MKV.tracks([
                MKV.track(1, type: 1, codec: "V_VP9", [
                    MKV.video(
                        width: 2560,
                        height: 1440,
                        [EBMLWriter.uint(0x54B0, 2560), EBMLWriter.uint(0x54BA, 1500)]
                    ),
                    EBMLWriter.uint(0x23E383, 40_000_000)
                ]),
                MKV.track(2, type: 2, codec: "A_OPUS", [
                    EBMLWriter.parent(
                        0xE1,
                        [EBMLWriter.float32(0xB5, 48000), EBMLWriter.uint(0x9F, 2)]
                    ),
                    EBMLWriter.element(0x63A2, Array("OpusHead".utf8)),
                    EBMLWriter.uint(0x56AA, 6_500_000), EBMLWriter.uint(0x56BB, 80_000_000)
                ])
            ])
        ]))
        #expect(file.container == .webM)
        #expect(file.info.timestampScale == 1_000_000)
        #expect(file.info.durationSeconds == 53.781)
        #expect(file.info.title == "Sample")
        #expect(file.tracks.map(\.number) == [1, 2])
        let video = try #require(file.track(number: 1))
        #expect(video.kind == .video)
        #expect(video.codecID == "V_VP9")
        #expect(video.uid == 1000)
        #expect(video.defaultDuration == 40_000_000)
        #expect(video.video?.pixelWidth == 2560)
        #expect(video.video?.displayHeight == 1500)
        let audio = try #require(file.track(number: 2))
        #expect(audio.audio?.samplingFrequency == 48000)
        #expect(audio.audio?.channels == 2)
        #expect(audio.codecPrivate == Data("OpusHead".utf8))
        #expect(audio.codecDelay == 6_500_000)
        #expect(audio.seekPreRoll == 80_000_000)
        #expect(file.firstClusterOffset == nil, "no clusters")
        #expect(file.cuesOffset == nil)
    }

    /// mkvmerge leaves out what equals the default: `Language` for English, `FlagDefault` for a default
    /// track. Read as "unknown", every English track would lose its language.
    @Test("an element a muxer left out takes the specification's default")
    func defaults() throws {
        let file = try MatroskaFile(source: MKV.file([
            MKV.tracks([MKV.track(1, type: 2, codec: "A_AC3", [EBMLWriter.parent(0xE1, [])])])
        ]))
        let track = try #require(file.tracks.first)
        #expect(track.language == "eng")
        #expect(track.isDefault)
        #expect(track.isEnabled)
        #expect(!track.isForced)
        #expect(track.audio?.channels == 1)
        #expect(track.audio?.samplingFrequency == 8000)
        #expect(track.frameEncoding == .none)
        #expect(file.info.timestampScale == 1_000_000, "a file with no Info keeps the default clock")
    }

    @Test("a BCP 47 language wins over the ISO 639-2 one, and \"und\" stays what it says")
    func languages() throws {
        let file = try MatroskaFile(source: MKV.file([
            MKV.tracks([
                MKV.track(1, type: 2, codec: "A_AC3", [
                    EBMLWriter.string(0x22B59C, "rus"), EBMLWriter.string(0x22B59D, "ru")
                ]),
                MKV.track(2, type: 2, codec: "A_AC3", [EBMLWriter.string(0x22B59D, "en")]),
                MKV.track(3, type: 2, codec: "A_AC3", [EBMLWriter.string(0x22B59C, "und")]),
                MKV.track(4, type: 0x11, codec: "S_TEXT/UTF8", [
                    EBMLWriter.uint(0x88, 0), EBMLWriter.uint(0x55AA, 1), EBMLWriter.uint(0xB9, 0)
                ])
            ])
        ]))
        #expect(file.tracks.map(\.language) == ["ru", "en", "und", "eng"])
        let subtitle = try #require(file.track(number: 4))
        #expect(subtitle.kind == .subtitle)
        #expect(!subtitle.isDefault)
        #expect(subtitle.isForced)
        #expect(!subtitle.isEnabled)
    }

    @Test("a TrackEntry with no number is left out, and an unknown type is kept by its number")
    func oddTracks() throws {
        let numberless = EBMLWriter.parent(
            0xAE,
            [EBMLWriter.uint(0x83, 1), EBMLWriter.string(0x86, "V_VP8")]
        )
        let file = try MatroskaFile(source: MKV.file([
            MKV.tracks([numberless, MKV.track(2, type: 0x42, codec: "X_THING")])
        ]))
        #expect(file.tracks.map(\.number) == [2])
        #expect(file.tracks.first?.kind == .other(0x42))
    }

    @Test("header stripping is undone; zlib, an empty compression, encryption and a stack are named")
    func encodings() throws {
        let file = try MatroskaFile(source: MKV.file([
            MKV.tracks([
                MKV.track(
                    1,
                    type: 2,
                    codec: "A_AC3",
                    [MKV.compression(algorithm: 3, settings: [0x0B, 0x77])]
                ),
                MKV.track(2, type: 0x11, codec: "S_HDMV/PGS", [MKV.compression(algorithm: nil)]),
                MKV.track(3, type: 2, codec: "A_AC3", [MKV.compression(algorithm: 2)]),
                MKV.track(4, type: 1, codec: "V_VP8", [
                    EBMLWriter.parent(0x6D80, [EBMLWriter.parent(0x6240, [
                        EBMLWriter.uint(0x5033, 1), EBMLWriter.parent(0x5035, [])
                    ])])
                ]),
                MKV.track(
                    5,
                    type: 2,
                    codec: "A_AC3",
                    [MKV.compression(algorithm: 3, settings: [1], scope: 3)]
                )
            ])
        ]))
        #expect(file.tracks.map(\.frameEncoding) == [
            .headerStripping(Data([0x0B, 0x77])),
            .compressed(algorithm: 0),
            .compressed(algorithm: 2),
            .encrypted,
            .compressed(algorithm: 3)
        ])
        #expect(file.tracks.map(\.frameEncoding.isReadable) == [true, false, false, false, false])
    }

    // MARK: - Finding the head

    /// The layout a muxer writing in one pass might leave: the head after the clusters, named by a
    /// second `SeekHead` that the first names.
    @Test(
        "Info, Tracks and the cues after the clusters are found through a SeekHead that names another"
    )
    func headAfterClusters() throws {
        let cluster = MKV.cluster(time: 0, [MKV.simpleBlock(track: 1, time: 0, frames: [[1, 2, 3]])])
        // Positions are counted from the segment's data, and a SeekHead's or a cue's size does not
        // depend on the positions it holds, so the layout can be measured before they are known.
        let placeholderSecond = MKV.seekHead([(0x1549A966, 0), (0x1654AE6B, 0), (0x1C53BB6B, 0)])
        let first = MKV.seekHead([(0x114D9B74, 0)])
        let info = MKV.info(duration: 10)
        let layout = [
            first,
            cluster,
            info,
            MKV.plainTracks,
            MKV.cues([(0, [(1, 0)])]),
            placeholderSecond
        ]
        let at = MKV.positions(layout)
        let cues = MKV.cues([(0, [(1, at[1])])])
        let second = MKV.seekHead([(0x1549A966, at[2]), (0x1654AE6B, at[3]), (0x1C53BB6B, at[4])])
        let children = [
            MKV.seekHead([(0x114D9B74, at[5])]),
            cluster,
            info,
            MKV.plainTracks,
            cues,
            second
        ]
        let file = try MatroskaFile(source: MKV.file(children))
        let base = MKV.segmentDataOffset(children)
        #expect(file.tracks.map(\.codecID) == ["V_MPEG4/ISO/AVC", "A_AC3"])
        #expect(file.info.duration == 10)
        #expect(file.firstClusterOffset == base + at[1])
        #expect(file.cuesOffset == base + at[4])
        #expect(try file.cues().first?.positions.first?.clusterOffset == base + at[1])
    }

    /// The film's second `SeekHead` lists every one of its 6 902 clusters, 121 KiB at the end of
    /// 10 GB, and nothing the head needs.
    @Test("opening reads neither the cues nor a second SeekHead the first made unnecessary")
    func opensLightly() throws {
        // A frame larger than the reader's window, so the cues lie past anything a read near the head
        // could take in on the way.
        let cluster = MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, frames: [Array(repeating: 7, count: 100_000)])
        ])
        let cues = MKV.cues([(0, [(1, 0)])])
        let template = [
            MKV.seekHead([(0x1C53BB6B, 0), (0x114D9B74, 0)]),
            MKV.info(),
            MKV.plainTracks,
            cluster,
            cues
        ]
        let second = MKV.seekHead([(0x1F43B675, 0)])
        let at = MKV.positions(template + [second])
        let children = [
            MKV.seekHead([(0x1C53BB6B, at[4]), (0x114D9B74, at[5])]),
            MKV.info(), MKV.plainTracks, cluster, cues,
            MKV.seekHead([(0x1F43B675, at[3])])
        ]
        let source = CountingByteSource(MKV.file(children))
        let file = try MatroskaFile(source: source)
        let base = MKV.segmentDataOffset(children)
        #expect(file.cuesOffset == base + at[4])
        #expect(
            !source.touched(base + at[4]..<source.length),
            "neither the cues nor the second SeekHead"
        )
        // And the cues are there when asked for.
        #expect(try file.cues().count == 1)
    }

    @Test("a SeekHead pointing at bytes that are no SeekHead is passed over, not a refusal")
    func damagedSeekHead() throws {
        // The first SeekHead names a second one inside a Void's zeros, and nothing names the cues, so
        // the reader goes looking.
        let template = [MKV.seekHead([(0x114D9B74, 0)]), MKV.info(), MKV.plainTracks, MKV.void(20)]
        let at = MKV.positions(template)
        let children = [MKV.seekHead([(0x114D9B74, at[3] + 2)])] + template.dropFirst()
        let file = try MatroskaFile(source: MKV.file(children))
        #expect(file.tracks.count == 2)
        #expect(file.cuesOffset == nil)
    }

    @Test("a segment and its first cluster of unknown size, as a live recording writes them")
    func unknownSegment() throws {
        let file = try MatroskaFile(source: MKV.file(segmentSize: .unknown, [
            MKV.info(), MKV.plainTracks,
            MKV.cluster(time: 0, [MKV.simpleBlock(track: 1, time: 0, frames: [[9]])], size: .unknown)
        ]))
        #expect(file.tracks.count == 2)
        #expect(file.firstClusterOffset != nil)
    }
}
