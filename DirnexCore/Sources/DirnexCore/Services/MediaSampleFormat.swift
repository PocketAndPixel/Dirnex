import Foundation

/// What a decoder needs to know about a track before its first frame (PLAN.md §M42 ▸ Slice 4), in the
/// terms the system's media frameworks take it: a four-character code, the sizes, and the
/// configuration bytes. The app turns it into a Core Media format description; the core keeps to bytes.
///
/// It says what the *file* holds, not whether this Mac can decode it: a VP8 track gets a format as
/// faithfully as an H.264 one, and the app asks the system whether a decoder answers to it. Measured
/// 2026-11-20 (P1): VideoToolbox refuses `vp08` with -12906 and AudioToolbox lists no `dtsc` among
/// the formats it decodes, while every other codec in this Mac's films and WebMs decoded.
public enum MediaSampleFormat: Equatable, Sendable {
    case video(Video)
    case audio(Audio)

    public struct Video: Equatable, Sendable {
        /// The codec type: `avc1`, `hvc1`, `av01`, `vp09`, `vp08`.
        public var codec: UInt32
        public var width: Int
        public var height: Int
        /// The sample description's extension atoms by their names (`avcC`, `hvcC`, `av1C`, `vpcC`),
        /// each the box's payload without its size and name.
        public var atoms: [String: Data]

        public init(codec: UInt32, width: Int, height: Int, atoms: [String: Data] = [:]) {
            self.codec = codec
            self.width = width
            self.height = height
            self.atoms = atoms
        }
    }

    public struct Audio: Equatable, Sendable {
        /// The format: `ac-3`, `ec-3`, `aac `, `opus`, `vorb`, `flac`, `.mp3`, `lpcm`.
        public var formatID: UInt32
        public var sampleRate: Double
        public var channels: Int
        /// Frames in every packet, or 0 where packets differ (Opus, Vorbis, FLAC), whose packets
        /// carry their own count when the core can tell it (`MediaPacket.frameCount`).
        public var framesPerPacket: Int
        /// For `lpcm` alone: how a sample is stored.
        public var pcm: PCMLayout?
        /// What the decoder reads before the first packet, in the layout the system's own encoders give
        /// theirs: an `ES_Descriptor` around AAC's `AudioSpecificConfig`, Opus's `OpusHead`, Vorbis's three
        /// headers as Matroska laces them, a whole `dfLa` box for FLAC.
        public var magicCookie: Data?

        public init(
            formatID: UInt32,
            sampleRate: Double,
            channels: Int,
            framesPerPacket: Int,
            pcm: PCMLayout? = nil,
            magicCookie: Data? = nil
        ) {
            self.formatID = formatID
            self.sampleRate = sampleRate
            self.channels = channels
            self.framesPerPacket = framesPerPacket
            self.pcm = pcm
            self.magicCookie = magicCookie
        }

        /// How long one packet plays, in nanoseconds, for a format whose packets all last the same.
        public var packetDuration: Int64? {
            guard framesPerPacket > 0, sampleRate > 0 else { return nil }
            return Int64((Double(framesPerPacket) * 1_000_000_000 / sampleRate).rounded())
        }
    }

    /// How uncompressed samples are stored.
    public struct PCMLayout: Equatable, Sendable {
        public var bitsPerSample: Int
        public var isFloat: Bool
        public var isBigEndian: Bool

        public init(bitsPerSample: Int, isFloat: Bool, isBigEndian: Bool) {
            self.bitsPerSample = bitsPerSample
            self.isFloat = isFloat
            self.isBigEndian = isBigEndian
        }

        /// Bytes in one frame of `channels` samples.
        public func bytesPerFrame(channels: Int) -> Int {
            (bitsPerSample + 7) / 8 * channels
        }
    }

    /// `text`'s four characters as a big-endian code, as Core Media writes codec types.
    public static func code(_ text: StaticString) -> UInt32 {
        text.withUTF8Buffer { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }
}

extension MatroskaTrack {
    /// What a decoder needs for this track, or `nil` for a codec the system's frameworks have no name
    /// for (Theora, TrueHD, RealVideo), a track that is neither picture nor sound, or one whose codec
    /// needs configuration the file leaves out: H.264 without its `avcC`, AV1 without its `av1C`.
    ///
    /// `firstFrame` is the track's first key frame, which VP9 needs: Matroska carries no `vpcC`, so its
    /// profile, bit depth and chroma come from the frame's own header (`VP9FrameHeader`). Every other
    /// codec ignores it.
    public func sampleFormat(firstFrame: Data? = nil) -> MediaSampleFormat? {
        switch kind {
        case .video: videoFormat(firstFrame: firstFrame).map(MediaSampleFormat.video)
        case .audio: audioFormat().map(MediaSampleFormat.audio)
        default: nil
        }
    }

    private func videoFormat(firstFrame: Data?) -> MediaSampleFormat.Video? {
        let width = Int(clamping: video?.pixelWidth ?? 0)
        let height = Int(clamping: video?.pixelHeight ?? 0)
        func configured(_ codec: StaticString, _ atom: String) -> MediaSampleFormat.Video? {
            guard let codecPrivate, !codecPrivate.isEmpty else { return nil }
            return .init(
                codec: MediaSampleFormat.code(codec),
                width: width,
                height: height,
                atoms: [atom: codecPrivate]
            )
        }
        switch codecID {
        case "V_MPEG4/ISO/AVC": return configured("avc1", "avcC")
        case "V_MPEGH/ISO/HEVC": return configured("hvc1", "hvcC")
        case "V_AV1": return configured("av01", "av1C")
        case "V_VP9":
            guard let firstFrame, let header = VP9FrameHeader(firstFrame) else { return nil }
            return .init(
                codec: MediaSampleFormat.code("vp09"),
                width: width,
                height: height,
                atoms: ["vpcC": header.configurationRecord(width: width, height: height)]
            )
        case "V_VP8": return .init(
                codec: MediaSampleFormat.code("vp08"),
                width: width,
                height: height
            )
        default: return nil
        }
    }

    private func audioFormat() -> MediaSampleFormat.Audio? {
        let rate = audio?.samplingFrequency ?? 8000
        let channels = Int(clamping: audio?.channels ?? 1)
        func plain(_ code: StaticString, _ frames: Int, rate: Double = rate) -> MediaSampleFormat.Audio {
            .init(
                formatID: MediaSampleFormat.code(code),
                sampleRate: rate,
                channels: channels,
                framesPerPacket: frames
            )
        }
        switch codecID {
        case "A_AC3", "A_AC3/BSID9", "A_AC3/BSID10": return plain("ac-3", 1536)
        case "A_EAC3": return plain("ec-3", 1536)
        case "A_DTS", "A_DTS/EXPRESS", "A_DTS/LOSSLESS": return plain("dtsc", 512)
        case "A_MPEG/L1": return plain(".mp1", 384)
        case "A_MPEG/L2": return plain(".mp2", 1152)
        // MPEG-2 and 2.5 Layer III, below 32 kHz, carry half as many frames to a packet.
        case "A_MPEG/L3": return plain(".mp3", rate < 32000 ? 576 : 1152)
        case "A_OPUS":
            // Opus always decodes at 48 kHz, whatever rate its header says the source had.
            var format = plain("opus", 0, rate: 48000)
            format.magicCookie = codecPrivate
            return codecPrivate == nil ? nil : format
        case "A_VORBIS":
            guard let codecPrivate, VorbisHeaders(codecPrivate: codecPrivate) != nil else { return nil }
            var format = plain("vorb", 0)
            format.magicCookie = codecPrivate
            return format
        case "A_FLAC":
            guard let cookie = FLACConfiguration.cookie(codecPrivate: codecPrivate) else { return nil }
            var format = plain(
                "flac",
                FLACConfiguration.fixedBlockSize(codecPrivate: codecPrivate) ?? 0
            )
            format.magicCookie = cookie
            return format
        default:
            if codecID.hasPrefix("A_AAC") { return aacFormat(rate: rate, channels: channels) }
            if codecID.hasPrefix("A_PCM/") { return pcmFormat(rate: rate, channels: channels) }
            return nil
        }
    }

    /// AAC, with its `AudioSpecificConfig` from the track or, for the old IDs that name the profile
    /// instead (`A_AAC/MPEG4/LC/SBR`), made from what the ID and the track say.
    private func aacFormat(rate: Double, channels: Int) -> MediaSampleFormat.Audio? {
        let config = codecPrivate.flatMap { $0.isEmpty ? nil : $0 }
            ?? AACConfiguration.audioSpecificConfig(
                codecID: codecID,
                sampleRate: rate,
                channels: channels
            )
        guard let config else { return nil }
        return .init(
            formatID: MediaSampleFormat.code("aac "),
            sampleRate: rate,
            channels: channels,
            framesPerPacket: 1024,
            magicCookie: AACConfiguration.magicCookie(audioSpecificConfig: config)
        )
    }

    private func pcmFormat(rate: Double, channels: Int) -> MediaSampleFormat.Audio? {
        let bits = Int(clamping: audio?.bitDepth ?? 16)
        let layout: MediaSampleFormat.PCMLayout
        switch codecID {
        case "A_PCM/INT/LIT": layout = .init(bitsPerSample: bits, isFloat: false, isBigEndian: false)
        case "A_PCM/INT/BIG": layout = .init(bitsPerSample: bits, isFloat: false, isBigEndian: true)
        case "A_PCM/FLOAT/IEEE": layout = .init(
                bitsPerSample: bits,
                isFloat: true,
                isBigEndian: false
            )
        default: return nil
        }
        guard [8, 16, 24, 32, 64].contains(bits), !layout.isFloat || bits >= 32 else { return nil }
        return .init(
            formatID: MediaSampleFormat.code("lpcm"),
            sampleRate: rate,
            channels: channels,
            framesPerPacket: 1,
            pcm: layout
        )
    }
}
