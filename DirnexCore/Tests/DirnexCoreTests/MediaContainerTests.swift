import Foundation
import Testing

@testable import DirnexCore

/// Which container a movie or a sound is kept in, for Quick View's card (PLAN.md §M42 ▸ Slice 2).
///
/// The fixtures are the first bytes of real files, captured 2026-11-19 from the container samples in
/// `~/swtest/video` and from a 10.5 GB Matroska film, so the sniff is held to what muxers write rather
/// than to what the specifications allow.
@Suite("Media containers")
struct MediaContainerTests {
    private static func captured(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return Data(bytes)
    }

    /// A captured file start and the container it should be named as.
    struct Sample: CustomTestStringConvertible, Sendable {
        let name: String
        let hex: String
        let container: MediaContainer

        init(_ name: String, _ hex: String, _ container: MediaContainer) {
            self.name = name
            self.hex = hex
            self.container = container
        }

        var testDescription: String { name }
    }

    static let samples: [Sample] = [
        Sample("avi", "524946460eed2002415649204c495354722200006864726c61766968380000", .avi),
        Sample("asf", "3026b2758e66cf11a6d900aa0062ce6c8f02000000000000060000000102a1dc", .asf),
        Sample("wmv", "3026b2758e66cf11a6d900aa0062ce6c9114000000000000080000000102a1dc", .asf),
        // An eight-byte size for the header and for nothing else, as this muxer writes it.
        Sample(
            "mkv",
            "1a45dfa301000000000000234286810142f7810142f2810442f381084282886d6174726f736b61428781044285810218",
            .matroska
        ),
        Sample(
            "webm",
            "1a45dfa3010000000000001f4286810142f7810142f2810442f381084282847765626d42878104428581021853806701",
            .webM
        ),
        // The film: one-byte sizes throughout.
        Sample(
            "film.mkv",
            "1a45dfa3a34286810142f7810142f2810442f381084282886d6174726f736b614287810242858102185380670100",
            .matroska
        ),
        Sample("ogv", "4f676753000200000000000000005da21c7500000000cde62d40012a8074686f", .ogg),
        Sample("rm", "2e524d46000000120000000000000000000650524f50000000320000009bab90", .realMedia),
        Sample("mxf", "060e2b34020501010d010201010204008300008800010003000000010000000000", .mxf),
        Sample("mp4", "00000020667479706d703432000000006d7034326d70343169736f6d61766331", .mpeg4),
        Sample("m4v", "0000001c667479704d3456200000020069736f6d69736f326176633100000008", .mpeg4),
        Sample("3gp", "0000001c6674797033677034000002003367703469736f6d69736f3200000008", .mpeg4),
        Sample("mov", "0000001466747970717420200000020071742020000000087769646502c7a1ed", .quickTime)
    ]

    @Test("each sample's first bytes name its container", arguments: samples)
    func samplesSniff(sample: Sample) {
        #expect(MediaContainer.sniff(Self.captured(sample.hex)) == sample.container)
    }

    /// The negative controls: bytes that open the same way and are something else, or that are cut off
    /// before they say.
    @Test("an EBML document of another kind, a WAV and a short file name nothing")
    func nearMisses() {
        // DocType "other" in an otherwise Matroska-shaped header.
        let other = Self.captured(
            "1a45dfa3984286810142f78101428285" + "6f74686572" + "4287810142858101"
        )
        #expect(MediaContainer.sniff(other) == nil)
        // A WAV is RIFF too, and AVFoundation plays it.
        #expect(MediaContainer.sniff(Self.captured("52494646240000005741564566")) == nil)
        // Cut off inside the header's DocType, and before the AVI form type.
        let cut = Self.captured("1a45dfa3a3428681014282886d6174")
        #expect(MediaContainer.sniff(cut) == nil)
        #expect(MediaContainer.sniff(Data("RIFF\u{0}\u{0}".utf8)) == nil)
        #expect(MediaContainer.sniff(Data()) == nil)
        #expect(MediaContainer.sniff(Data("hello, world\n".utf8)) == nil)
    }

    @Test("a DocType padded with NULs to its size still names the container")
    func paddedDocType() {
        let webm = Self.captured("1a45dfa389428286" + "7765626d0000")
        #expect(MediaContainer.sniff(webm) == .webM)
    }

    @Test("the extensions macOS may leave untyped name their containers")
    func extensions() {
        #expect(MediaContainer(fileExtension: "mkv") == .matroska)
        #expect(MediaContainer(fileExtension: "MKV") == .matroska)
        #expect(MediaContainer(fileExtension: "webm") == .webM)
        #expect(MediaContainer(fileExtension: "wmv") == .asf)
        #expect(MediaContainer(fileExtension: "opus") == .ogg)
        #expect(MediaContainer(fileExtension: "mp4") == nil, "macOS types what AVFoundation plays")
        #expect(MediaContainer(fileExtension: "ts") == nil, "a TypeScript file is not a movie here")
        #expect(
            MediaContainer(fileExtension: "spx") == nil,
            "macOS types it as a System Profiler report"
        )
        #expect(MediaContainer(fileExtension: "") == nil)
    }
}
