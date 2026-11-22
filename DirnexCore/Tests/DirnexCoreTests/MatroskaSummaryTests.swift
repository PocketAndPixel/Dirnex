import Foundation
import Testing

@testable import DirnexCore

/// What a Matroska track's codec is called, and the summary Quick View's card makes of a file's tracks
/// (PLAN.md §M42 ▸ Slice 3).
@Suite("Matroska codec names")
struct MatroskaSummaryTests {
    @Test("Matroska's codec IDs read as the names AVFoundation's codes get")
    func names() {
        let pairs: [(String, String)] = [
            ("V_MPEG4/ISO/AVC", "H.264"), ("V_MPEGH/ISO/HEVC", "HEVC"), ("V_VP8", "VP8"),
            ("V_VP9", "VP9"),
            ("V_AV1", "AV1"), ("V_MPEG4/ISO/ASP", "MPEG-4"), ("V_MPEG2", "MPEG-2"),
            ("V_THEORA", "Theora"),
            ("A_AAC", "AAC"), ("A_AAC/MPEG4/LC", "AAC"), ("A_AAC/MPEG4/LC/SBR", "HE-AAC"),
            ("A_AC3", "AC-3"), ("A_EAC3", "E-AC-3"), ("A_DTS", "DTS"),
            ("A_DTS/LOSSLESS", "DTS-HD MA"),
            ("A_TRUEHD", "TrueHD"), ("A_MPEG/L3", "MP3"), ("A_VORBIS", "Vorbis"),
            ("A_OPUS", "Opus"),
            ("A_FLAC", "FLAC"), ("A_PCM/INT/LIT", "PCM"), ("A_REAL/COOK", "RealAudio"),
            ("V_REAL/RV40", "RealVideo")
        ]
        for (id, name) in pairs {
            #expect(MediaCodecName.name(matroskaCodecID: id) == name, "\(id)")
        }
        // The same words as the four-character codes, so a film reads alike whichever reader read it.
        #expect(
            MediaCodecName.name(matroskaCodecID: "A_AC3") == MediaCodecName.name(for: 0x6163_2D33)
        )
        #expect(
            MediaCodecName.name(matroskaCodecID: "V_MPEG4/ISO/AVC") == MediaCodecName.name(
                for: 0x6176_6331
            )
        )
    }

    @Test("a Windows codec wrapped in Matroska is named by the code in its Windows header")
    func windowsCodecs() {
        // A BITMAPINFOHEADER: 40 bytes, the compression code at byte 16.
        var bitmap = Data(count: 40)
        bitmap.replaceSubrange(16..<20, with: Data("XVID".utf8))
        #expect(
            MediaCodecName.name(matroskaCodecID: "V_MS/VFW/FOURCC", codecPrivate: bitmap) == "MPEG-4"
        )
        bitmap.replaceSubrange(16..<20, with: Data("WVC1".utf8))
        #expect(
            MediaCodecName.name(matroskaCodecID: "V_MS/VFW/FOURCC", codecPrivate: bitmap) == "VC-1"
        )
        bitmap.replaceSubrange(16..<20, with: Data("ABCD".utf8))
        #expect(
            MediaCodecName.name(matroskaCodecID: "V_MS/VFW/FOURCC", codecPrivate: bitmap) == "ABCD"
        )
        // A WAVEFORMATEX: the format tag little-endian at its start.
        #expect(
            MediaCodecName.name(matroskaCodecID: "A_MS/ACM", codecPrivate: Data([0x00, 0x20])) == "AC-3"
        )
        #expect(
            MediaCodecName.name(matroskaCodecID: "A_MS/ACM", codecPrivate: Data([0x61, 0x01])) == "WMA"
        )
        #expect(
            MediaCodecName.name(matroskaCodecID: "A_MS/ACM", codecPrivate: Data([0x34, 0x12])) == "0x1234"
        )
        // No header to read: the ID itself.
        #expect(MediaCodecName.name(matroskaCodecID: "V_MS/VFW/FOURCC") == "V_MS/VFW/FOURCC")
    }

    @Test("an ID nothing here knows is shown as itself")
    func unknown() {
        #expect(MediaCodecName.name(matroskaCodecID: "V_SOMETHING_NEW") == "V_SOMETHING_NEW")
    }

    @Test("the summary takes the first picture's size and every sound's codec, once each")
    func summary() throws {
        let file = try MatroskaFile(source: MKV.file([
            MKV.info(duration: 90000),
            MKV.tracks([
                MKV.track(1, type: 0x11, codec: "S_TEXT/UTF8"),
                MKV.track(
                    2,
                    type: 1,
                    codec: "V_MPEGH/ISO/HEVC",
                    [MKV.video(width: 3840, height: 1600)]
                ),
                MKV.track(3, type: 2, codec: "A_TRUEHD"),
                MKV.track(4, type: 2, codec: "A_AC3"),
                MKV.track(5, type: 2, codec: "A_AC3")
            ])
        ]))
        let summary = MediaSummary(matroska: file)
        #expect(summary.duration == 90)
        #expect(summary.facts == "3840×1600 · HEVC · TrueHD, AC-3")
    }
}
