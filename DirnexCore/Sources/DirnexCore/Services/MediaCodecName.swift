import Foundation

/// What a codec is called, from the four-character code a format description carries (PLAN.md §M42 ▸
/// Slice 2), for Quick View's header and its card.
///
/// The codes are the ones AVFoundation reports as a track's media subtype. Measured 2026-11-19 over a
/// sample of each container it opens: `avc1` for H.264 in MP4, MOV, TS and MTS alike, `mp4v` for
/// MPEG-4 Part 2 in 3GP, `mp1v` and `mp2v` for MPEG-1 and MPEG-2 video, `aac ` for AAC, and `.mp2` for
/// MPEG-1 Layer II audio. A code missing here is shown as itself, which is what a codec's name is to
/// anyone who has met it before, rather than dropped.
///
/// The names are the codecs' own and are not translated.
public enum MediaCodecName {
    /// The name for `code`, a big-endian four-character code as Core Media hands it over.
    public static func name(for code: UInt32) -> String {
        let text = fourCharacterText(code)
        return names[text] ?? fallback(text)
    }

    private static let names: [String: String] = [
        // Video.
        "avc1": "H.264", "avc3": "H.264",
        "hvc1": "HEVC", "hev1": "HEVC",
        "dvh1": "Dolby Vision", "dvhe": "Dolby Vision",
        "mp4v": "MPEG-4", "mp1v": "MPEG-1", "mp2v": "MPEG-2",
        "h263": "H.263", "s263": "H.263",
        "vp08": "VP8", "vp09": "VP9", "av01": "AV1",
        "jpeg": "Motion JPEG", "mjpa": "Motion JPEG", "mjpb": "Motion JPEG", "dmb1": "Motion JPEG",
        "apco": "ProRes 422 Proxy", "apcs": "ProRes 422 LT", "apcn": "ProRes 422",
        "apch": "ProRes 422 HQ", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
        "aprn": "ProRes RAW", "aprh": "ProRes RAW HQ",
        "dvc ": "DV", "dvcp": "DV", "dvpp": "DV", "dv5n": "DV", "dv5p": "DV",
        "cvid": "Cinepak", "SVQ1": "Sorenson Video", "SVQ3": "Sorenson Video 3",
        "png ": "PNG", "rle ": "Animation", "raw ": "Uncompressed",
        // Sound.
        "aac ": "AAC", "mp4a": "AAC", "aach": "HE-AAC", "aacp": "HE-AAC v2",
        "aacl": "AAC-LD", "aace": "AAC-ELD", "usac": "xHE-AAC",
        ".mp1": "MP1", ".mp2": "MP2", ".mp3": "MP3",
        "ac-3": "AC-3", "ec-3": "E-AC-3", "ac-4": "AC-4",
        "dtsc": "DTS", "dtsh": "DTS-HD", "dtsl": "DTS-HD MA", "dtse": "DTS Express",
        "flac": "FLAC", "opus": "Opus", "alac": "ALAC",
        "lpcm": "PCM", "twos": "PCM", "sowt": "PCM", "in24": "PCM", "in32": "PCM",
        "fl32": "PCM", "fl64": "PCM",
        "ulaw": "μ-law", "alaw": "A-law", "ima4": "IMA ADPCM",
        "samr": "AMR", "sawb": "AMR-WB", "Qclp": "QCELP", "QDM2": "QDesign"
    ]

    /// A code with no name here, shown as the code with its padding trimmed (`"vp10"`, `"xyz"`), or as
    /// hexadecimal when it is not printable.
    private static func fallback(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "?" : trimmed
    }

    /// `code` as its four characters, or `0x…` when a byte is not printable ASCII.
    static func fourCharacterText(_ code: UInt32) -> String {
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: code >> (24 - 8 * $0)) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let text = String(bytes: bytes, encoding: .ascii)
        else { return String(format: "0x%08X", code) }
        return text
    }
}
