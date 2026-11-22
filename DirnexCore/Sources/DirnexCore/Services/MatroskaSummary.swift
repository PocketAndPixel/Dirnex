import Foundation

extension MediaCodecName {
    /// What a codec is called, from the ID a Matroska track names it by (`V_MPEG4/ISO/AVC`, `A_AC3`),
    /// in the same words `name(for:)` gives the four-character codes AVFoundation reports, so a film
    /// reads the same whichever of the two read it (PLAN.md §M42 ▸ Slice 3).
    ///
    /// The two IDs that wrap a Windows codec (`V_MS/VFW/FOURCC`, `A_MS/ACM`) are named by the code in
    /// `codecPrivate`'s Windows header. An ID missing here is shown as itself, as an unknown four-
    /// character code is.
    public static func name(matroskaCodecID id: String, codecPrivate: Data? = nil) -> String {
        if let name = matroskaNames[id] { return name }
        if id.hasPrefix("A_AAC") { return id.hasSuffix("/SBR") ? "HE-AAC" : "AAC" }
        if id.hasPrefix("A_REAL/") || id.hasPrefix("V_REAL/") {
            return id.hasPrefix("V_") ? "RealVideo" : "RealAudio"
        }
        if id == "V_MS/VFW/FOURCC", let code = windowsVideoCode(codecPrivate) {
            return windowsVideoNames[code.uppercased()] ?? code.trimmingCharacters(in: .whitespaces)
        }
        if id == "A_MS/ACM", let tag = windowsAudioTag(codecPrivate) {
            return windowsAudioNames[tag] ?? String(format: "0x%04X", tag)
        }
        return id
    }

    private static let matroskaNames: [String: String] = [
        // Video.
        "V_MPEG4/ISO/AVC": "H.264", "V_MPEGH/ISO/HEVC": "HEVC", "V_MPEGI/ISO/VVC": "VVC",
        "V_MPEG4/ISO/SP": "MPEG-4", "V_MPEG4/ISO/ASP": "MPEG-4", "V_MPEG4/ISO/AP": "MPEG-4",
        "V_MPEG4/MS/V3": "MPEG-4 v3", "V_MPEG1": "MPEG-1", "V_MPEG2": "MPEG-2",
        "V_VP8": "VP8", "V_VP9": "VP9", "V_AV1": "AV1", "V_THEORA": "Theora",
        "V_PRORES": "ProRes", "V_MJPEG": "Motion JPEG", "V_FFV1": "FFV1", "V_DIRAC": "Dirac",
        "V_UNCOMPRESSED": "Uncompressed", "V_AVS2": "AVS2", "V_AVS3": "AVS3",
        // Sound.
        "A_AC3": "AC-3", "A_AC3/BSID9": "AC-3", "A_AC3/BSID10": "AC-3", "A_EAC3": "E-AC-3",
        "A_DTS": "DTS", "A_DTS/EXPRESS": "DTS Express", "A_DTS/LOSSLESS": "DTS-HD MA",
        "A_TRUEHD": "TrueHD", "A_MLP": "MLP",
        "A_MPEG/L1": "MP1", "A_MPEG/L2": "MP2", "A_MPEG/L3": "MP3",
        "A_VORBIS": "Vorbis", "A_OPUS": "Opus", "A_FLAC": "FLAC", "A_ALAC": "ALAC",
        "A_PCM/INT/LIT": "PCM", "A_PCM/INT/BIG": "PCM", "A_PCM/FLOAT/IEEE": "PCM",
        "A_TTA1": "TTA", "A_WAVPACK4": "WavPack", "A_MPC": "Musepack",
        "A_QUICKTIME/QDMC": "QDesign", "A_QUICKTIME/QDM2": "QDesign", "A_ATRAC/AT1": "ATRAC"
    ]

    /// The compression code of a `BITMAPINFOHEADER`, which a Video for Windows track carries as its
    /// private data: four characters at byte 16.
    private static func windowsVideoCode(_ header: Data?) -> String? {
        guard let header, header.count >= 20 else { return nil }
        let bytes = [UInt8](header[header.startIndex + 16..<header.startIndex + 20])
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    /// Video for Windows compression codes, upper-cased, as Matroska's VfW tracks and AVI's streams
    /// name their codecs (PLAN.md §M42 ▸ Slices 3 and 5).
    static let windowsVideoNames: [String: String] = [
        "XVID": "MPEG-4", "DIVX": "MPEG-4", "DX50": "MPEG-4", "FMP4": "MPEG-4", "MP4V": "MPEG-4",
        "MP4S": "MPEG-4", "M4S2": "MPEG-4", "3IV2": "MPEG-4",
        "DIV3": "MPEG-4 v3", "DIV4": "MPEG-4 v3", "MP43": "MPEG-4 v3", "MP42": "MPEG-4 v2",
        "H264": "H.264", "X264": "H.264", "AVC1": "H.264", "DAVC": "H.264",
        "HEVC": "HEVC", "H265": "HEVC", "HVC1": "HEVC",
        "WVC1": "VC-1", "WMV1": "Windows Media Video", "WMV2": "Windows Media Video",
        "WMV3": "Windows Media Video", "MJPG": "Motion JPEG", "MPG2": "MPEG-2", "HFYU": "HuffYUV",
        "CVID": "Cinepak", "DVSD": "DV", "IV50": "Indeo", "IV41": "Indeo", "IV32": "Indeo",
        "MSVC": "Microsoft Video 1", "VP80": "VP8", "VP90": "VP9", "FFV1": "FFV1"
    ]

    /// The format tag of a `WAVEFORMATEX`, little-endian at its start.
    private static func windowsAudioTag(_ header: Data?) -> UInt16? {
        guard let header, header.count >= 2 else { return nil }
        return UInt16(header[header.startIndex]) | UInt16(header[header.startIndex + 1]) << 8
    }

    /// `WAVEFORMATEX` format tags.
    static let windowsAudioNames: [UInt16: String] = [
        0x0001: "PCM", 0x0003: "PCM", 0x0050: "MP2", 0x0055: "MP3",
        0x0002: "MS ADPCM", 0x0011: "IMA ADPCM", 0x0006: "A-law", 0x0007: "µ-law",
        0x0031: "GSM 6.10",
        0x0160: "WMA", 0x0161: "WMA", 0x0162: "WMA Pro", 0x0163: "WMA Lossless",
        0x00FF: "AAC", 0x1600: "AAC", 0x1610: "AAC", 0x706D: "AAC", 0x4143: "AAC",
        0x2000: "AC-3", 0x2001: "DTS", 0xF1AC: "FLAC"
    ]
}

extension MediaSummary {
    /// What Quick View's header and card say of a Matroska or WebM file, from its own head rather than
    /// AVFoundation, which reports nothing about a file it refuses (PLAN.md §M42 ▸ Slice 2's finding).
    ///
    /// The picture is the first video track's, in pixels: the film's `DisplayHeight` of 1094 over 1080
    /// stored rows is how to stretch it, and the header's other picture sizes are the stored ones too.
    public init(matroska file: MatroskaFile) {
        self.init(duration: file.info.durationSeconds)
        for track in file.tracks {
            let name = MediaCodecName.name(
                matroskaCodecID: track.codecID,
                codecPrivate: track.codecPrivate
            )
            switch track.kind {
            case .video:
                videoCodecs.append(name)
                if pictureSize == nil, let video = track.video {
                    pictureSize = PictureSize(
                        width: Int(clamping: video.pixelWidth),
                        height: Int(clamping: video.pixelHeight)
                    )
                }
            case .audio:
                audioCodecs.append(name)
            default:
                break
            }
        }
    }
}
