import Foundation
import Testing

@testable import DirnexCore

/// The Matroska reader held to real files (PLAN.md §M42 ▸ Slice 3): six captured 2026-11-20 from this
/// Mac, one per muxer, as the bytes a reader needs and nothing else (`SparseCaptureSource`).
///
/// Every expected number here came from a separate walk of the whole file in Python, written apart from
/// the Swift reader, and the frames' first bytes are a witness neither walk controls: each laced AC-3
/// frame has to begin with the codec's sync word `0B77` and each DTS frame with `7FFE8001`, which only
/// the right frame boundaries find.
///
/// - `film.mkv`: mkvmerge 3.4 (2010). H.264, five AC-3 and four DTS tracks laced eight to a block,
///   subtitles in `BlockGroup`s, chapters, cues at the end of 10.5 GB, and a second `SeekHead` there.
/// - `prism.mkv`: NCH Prism. An eight-byte size on nearly every element, VP8 and AAC.
/// - `mkvmerge6.mkv` and `mkvmerge88.mkv`: TV episodes; zlib-compressed PGS subtitles, and BCP 47
///   languages with the English ones' `Language` left out.
/// - `lavf-alpha.webm`: FFmpeg's Lavf, every VP9 frame in a `BlockGroup` (its alpha rides along).
/// - `libwebm-opus.webm`: libwebm, VP9 and Opus with its codec delay, cues naming block numbers.
@Suite("Matroska, real files")
struct MatroskaCapturedTests {
    private func open(_ name: String) throws -> MatroskaFile {
        try MatroskaFile(source: SparseCaptureSource(fixture: name))
    }

    private func firstCluster(_ file: MatroskaFile) throws -> MatroskaCluster {
        let offset = try #require(file.firstClusterOffset)
        return try #require(try file.cluster(from: offset))
    }

    /// Blocks per track.
    private func counts(_ cluster: MatroskaCluster) -> [UInt64: Int] {
        cluster.blocks.reduce(into: [:]) { $0[$1.track, default: 0] += 1 }
    }

    /// Each frame's first `count` bytes, as hex, for the frames of `tracks`.
    private func heads(
        _ file: MatroskaFile,
        _ cluster: MatroskaCluster,
        tracks: Set<UInt64>,
        count: Int
    ) throws -> Set<String> {
        var heads: Set<String> = []
        for block in cluster.blocks where tracks.contains(block.track) {
            for index in block.frames.indices {
                heads.insert(
                    try file.frame(index, of: block).prefix(count).map { String(format: "%02x", $0) }.joined(
                    )
                )
            }
        }
        return heads
    }

    // MARK: - The film

    @Test("the film's head: thirteen tracks, its clock and its length")
    func filmHead() throws {
        let file = try open("film.mkv")
        #expect(file.container == .matroska)
        #expect(file.info.timestampScale == 1_000_000)
        #expect(file.info.durationSeconds == 5723.872)
        #expect(file.info.writingApp?.hasPrefix("mkvmerge v3.4.0") == true)
        #expect(file.info.title?.hasPrefix("Планета сокровищ / Treasure Planet") == true)
        #expect(file.tracks.map(\.codecID) == [
            "V_MPEG4/ISO/AVC", "A_AC3", "A_DTS", "A_DTS", "A_DTS", "A_AC3", "A_AC3", "A_AC3",
            "A_DTS",
            "A_AC3", "S_TEXT/UTF8", "S_TEXT/UTF8", "S_TEXT/UTF8"
        ])
        #expect(file.tracks.map(\.language) == [
            "eng", "rus", "rus", "rus", "rus", "rus", "rus", "ukr", "eng", "eng", "rus", "eng",
            "eng"
        ])
        // The muxer marked one audio track default and the picture not, which a player has to cope with.
        #expect(file.tracks.filter(\.isDefault).map(\.number) == [2])
        let video = try #require(file.track(number: 1)?.video)
        #expect(video.pixelWidth == 1816)
        #expect(video.pixelHeight == 1080)
        #expect(video.displayHeight == 1094)
        #expect(
            file.track(number: 1)?.codecPrivate?.prefix(2) == Data([0x01, 0x64]),
            "avcC, High profile"
        )
        #expect(file.track(number: 2)?.defaultDuration == 32_000_000)
        #expect(file.track(number: 3)?.defaultDuration == nil)
        #expect(file.track(number: 7)?.audio?.channels == 2)
        #expect(file.firstClusterOffset == 7789)
        #expect(file.cuesOffset == 10_491_613_321)
    }

    @Test("the film's 1 126 cues, from the start of the file to near its end")
    func filmCues() throws {
        let cues = try open("film.mkv").cues()
        #expect(cues.count == 1126)
        #expect(cues.first?.time == 0)
        #expect(cues.first?.positions.map(\.clusterOffset) == [7789])
        #expect(cues.dropFirst().first?.time == 2878)
        #expect(cues.dropFirst().first?.positions.first?.clusterOffset == 3_011_761)
        #expect(cues.last?.time == 5_716_169)
        #expect(cues.last?.positions.first?.clusterOffset == 10_481_031_014)
        #expect(cues.allSatisfy { $0.positions.map(\.track) == [1] }, "only the picture is cued")
    }

    @Test("the film's first cluster: 137 blocks, every laced frame on its codec's sync word")
    func filmCluster() throws {
        let file = try open("film.mkv")
        let cluster = try firstCluster(file)
        #expect(cluster.timestamp == 0)
        #expect(cluster.blocks.count == 137)
        #expect(cluster.nextOffset == 1_509_100)
        #expect(!cluster.isTruncated)
        #expect(
            counts(cluster) == [
                1: 34,
                2: 6,
                3: 18,
                4: 18,
                5: 18,
                6: 6,
                7: 6,
                8: 6,
                9: 18,
                10: 6,
                13: 1
            ]
        )
        #expect(cluster.blocks.filter { $0.track == 1 && $0.isKeyframe }.count == 1)
        let ac3 = cluster.blocks.filter { [2, 6, 7, 8, 10].contains($0.track) }
        let dts = cluster.blocks.filter { [3, 4, 5, 9].contains($0.track) }
        #expect(ac3.reduce(0) { $0 + $1.frames.count } == 5 * 47)
        #expect(dts.reduce(0) { $0 + $1.frames.count } == 4 * 140)
        #expect(try heads(file, cluster, tracks: [2, 6, 7, 8, 10], count: 2) == ["0b77"])
        #expect(try heads(file, cluster, tracks: [3, 4, 5, 9], count: 4) == ["7ffe8001"])
        // An H.264 frame opens with a four-byte NAL length that fits inside it.
        for block in cluster.blocks where block.track == 1 {
            let length = try file.frame(0, of: block).prefix(4).reduce(0) { $0 << 8 | Int($1) }
            #expect(length > 0 && length + 4 <= block.frames[0].count)
        }
        let subtitle = try #require(cluster.blocks.first { $0.track == 13 })
        #expect(subtitle.timestamp == 1376)
        #expect(subtitle.duration == 2376)
        let laced = try #require(cluster.blocks.first { $0.track == 2 })
        #expect(laced.frames.prefix(2) == [12460..<13996, 13996..<15532])
        #expect((0..<3).map { file.frameTime($0, of: laced) } == [0, 32_000_000, 64_000_000])
        let firstDTS = try #require(dts.first)
        #expect(file.frameTime(1, of: firstDTS) == nil, "mkvmerge 3.4 gave DTS no default duration")
    }

    @Test("the film reads as Quick View's card names it")
    func filmSummary() throws {
        let summary = try MediaSummary(matroska: open("film.mkv"))
        #expect(summary.facts == "1816×1080 · H.264 · AC-3, DTS")
        #expect(summary.duration == 5723.872)
    }

    // MARK: - The other muxers

    @Test("NCH Prism's eight-byte sizes, VP8 and AAC")
    func prism() throws {
        let file = try open("prism.mkv")
        #expect(file.info.writingApp == "Prism Trial Version © NCH Software")
        #expect(file.tracks.map(\.codecID) == ["V_VP8", "A_AAC"])
        #expect(file.tracks.map(\.language) == ["und", "und"])
        #expect(file.track(number: 2)?.codecPrivate == Data([0x11, 0x90]))
        #expect(file.track(number: 2)?.audio?.bitDepth == 16)
        let cues = try file.cues()
        #expect(cues.count == 112)
        #expect(cues.last?.positions.first?.clusterOffset == 79_544_633)
        let cluster = try firstCluster(file)
        #expect(cluster.offset == 571)
        #expect(counts(cluster) == [1: 12, 2: 18])
        #expect(cluster.nextOffset == 1_328_355)
        #expect(MediaSummary(matroska: file).facts == "2560×1440 · VP8 · AAC")
    }

    @Test("mkvmerge 6.8's zlib subtitles and the language it left out")
    func mkvmerge6() throws {
        let file = try open("mkvmerge6.mkv")
        #expect(file.tracks.count == 13)
        #expect(file.tracks.filter { $0.codecID == "S_HDMV/PGS" }.map(\.frameEncoding)
            == Array(repeating: .compressed(algorithm: 0), count: 4))
        #expect(file.track(number: 1)?.language == "und")
        #expect(file.track(number: 5)?.language == "eng", "no Language element: the default")
        let cluster = try firstCluster(file)
        #expect(counts(cluster) == [1: 36, 2: 8, 3: 8, 4: 8, 5: 8])
        #expect(cluster.nextOffset == 1_625_390)
        #expect(try heads(file, cluster, tracks: [2, 3, 4, 5], count: 2) == ["0b77"])
    }

    @Test("mkvmerge 88's BCP 47 languages and E-AC-3")
    func mkvmerge88() throws {
        let file = try open("mkvmerge88.mkv")
        #expect(file.tracks.map(\.language) == ["en", "ru", "en", "ru", "ru", "en", "en"])
        #expect(file.tracks.map(\.codecID).prefix(3) == ["V_MPEG4/ISO/AVC", "A_AC3", "A_EAC3"])
        let cluster = try firstCluster(file)
        #expect(counts(cluster) == [1: 72, 2: 12, 3: 12])
        #expect(cluster.nextOffset == 444_892)
        #expect(try heads(file, cluster, tracks: [2, 3], count: 2) == ["0b77"])
        #expect(MediaSummary(matroska: file).facts == "1918×802 · H.264 · AC-3, E-AC-3")
    }

    @Test("Lavf's BlockGroups: one keyframe, every other frame naming its reference")
    func lavfBlockGroups() throws {
        let file = try open("lavf-alpha.webm")
        #expect(file.container == .webM)
        #expect(file.tracks.map(\.codecID) == ["V_VP9"])
        #expect(file.track(number: 1)?.defaultDuration == 16_670_000)
        let cluster = try firstCluster(file)
        #expect(cluster.blocks.count == 128)
        #expect(cluster.blocks.map(\.isKeyframe) == [true] + Array(repeating: false, count: 127))
        #expect(cluster.blocks.dropFirst().first?.timestamp == 67)
        #expect(cluster.nextOffset == 611_000)
        // A VP9 frame's first two bits are its frame marker, 0b10.
        for block in cluster.blocks {
            #expect(try file.frame(0, of: block).first.map { $0 & 0xC0 } == 0x80)
        }
        #expect(try file.cues().map(\.time) == [0, 2184])
    }

    @Test("libwebm's Opus: codec delay, pre-roll, and cues by block number")
    func libwebmOpus() throws {
        let file = try open("libwebm-opus.webm")
        let opus = try #require(file.track(number: 2))
        #expect(opus.codecID == "A_OPUS")
        #expect(opus.codecDelay == 6_500_000)
        #expect(opus.seekPreRoll == 80_000_000)
        #expect(opus.codecPrivate?.prefix(8) == Data("OpusHead".utf8))
        #expect(file.track(number: 1)?.language == "eng", "libwebm wrote no Language")
        let cues = try file.cues()
        #expect(cues.map(\.time) == [0, 2133, 4267])
        #expect(cues.first?.positions.first?.blockNumber == 2)
        #expect(cues.first?.positions.first?.clusterOffset == 387)
        let cluster = try firstCluster(file)
        #expect(counts(cluster) == [1: 128, 2: 213])
        #expect(cluster.nextOffset == 168_334)
        // Every Opus packet here opens with the same table-of-contents byte.
        #expect(try heads(file, cluster, tracks: [2], count: 1) == ["f4"])
        #expect(MediaSummary(matroska: file).facts == "1920×1200 · VP9 · Opus")
    }
}
