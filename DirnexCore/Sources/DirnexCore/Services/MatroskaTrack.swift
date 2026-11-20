import Foundation

/// One track of a Matroska or WebM file, as its `TrackEntry` describes it (PLAN.md §M42 ▸ Slice 3).
///
/// Every value an element may leave out takes the default the Matroska specification gives it, which
/// muxers rely on: mkvmerge leaves out `Language` for an English track and `FlagDefault` for a default
/// one (seen 2026-11-20 across mkvmerge 3.4, 6.8, 57 and 88), so reading an absent element as "unknown"
/// would call every such track something it is not.
public struct MatroskaTrack: Equatable, Sendable {
    /// What a track carries, by `TrackType`.
    public enum Kind: Equatable, Sendable {
        case video
        case audio
        case complex
        case logo
        case subtitle
        case buttons
        case control
        case metadata
        case other(UInt64)

        init(_ type: UInt64) {
            self = switch type {
            case 1: .video
            case 2: .audio
            case 3: .complex
            case 0x10: .logo
            case 0x11: .subtitle
            case 0x12: .buttons
            case 0x20: .control
            case 0x21: .metadata
            default: .other(type)
            }
        }
    }

    /// The picture's dimensions.
    public struct Video: Equatable, Sendable {
        public var pixelWidth: UInt64 = 0
        public var pixelHeight: UInt64 = 0
        /// The size to show the picture at, in `displayUnit`s; the pixel size when the file gives none.
        public var displayWidth: UInt64?
        public var displayHeight: UInt64?
        /// 0 for pixels, 1 centimetres, 2 inches, 3 an aspect ratio, 4 unknown.
        public var displayUnit: UInt64 = 0

        public init(
            pixelWidth: UInt64 = 0,
            pixelHeight: UInt64 = 0,
            displayWidth: UInt64? = nil,
            displayHeight: UInt64? = nil,
            displayUnit: UInt64 = 0
        ) {
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.displayWidth = displayWidth
            self.displayHeight = displayHeight
            self.displayUnit = displayUnit
        }
    }

    /// The sound's shape.
    public struct Audio: Equatable, Sendable {
        public var samplingFrequency: Double = 8000
        /// The rate after decoding, where it differs: an HE-AAC track doubles it.
        public var outputSamplingFrequency: Double?
        public var channels: UInt64 = 1
        public var bitDepth: UInt64?

        public init(
            samplingFrequency: Double = 8000,
            outputSamplingFrequency: Double? = nil,
            channels: UInt64 = 1,
            bitDepth: UInt64? = nil
        ) {
            self.samplingFrequency = samplingFrequency
            self.outputSamplingFrequency = outputSamplingFrequency
            self.channels = channels
            self.bitDepth = bitDepth
        }
    }

    /// The track's number, which its blocks name it by.
    public var number: UInt64 = 0
    public var uid: UInt64?
    public var kind: Kind = .other(0)
    /// The codec, as Matroska names it: `V_MPEG4/ISO/AVC`, `A_AC3`, `A_OPUS`.
    public var codecID: String = ""
    /// What the decoder needs before the first frame: an `avcC` record for H.264, an
    /// `AudioSpecificConfig` for AAC, Vorbis's three header packets.
    public var codecPrivate: Data?
    public var codecName: String?
    public var name: String?
    /// The language as BCP 47 when the file names one, else its ISO 639-2 code, else `eng`, the
    /// specification's default. `und` is a file saying it does not know.
    public var language: String = "eng"
    public var isEnabled = true
    public var isDefault = true
    public var isForced = false
    /// How long each frame lasts, in nanoseconds, when every frame lasts the same.
    public var defaultDuration: UInt64?
    /// Nanoseconds of decoded sound to drop from the start (Opus's pre-skip).
    public var codecDelay: UInt64 = 0
    /// Nanoseconds to decode before a seek's target for the sound to be right (Opus's 80 ms).
    public var seekPreRoll: UInt64 = 0
    public var video: Video?
    public var audio: Audio?
    /// What was done to every frame's bytes when they were written.
    public var frameEncoding: MatroskaFrameEncoding = .none

    public init() {}
}

/// What a muxer did to a track's frames (`ContentEncodings`), which a reader must undo before a
/// decoder sees them.
public enum MatroskaFrameEncoding: Equatable, Sendable {
    case none
    /// Bytes every frame began with, taken off each one to save space (`ContentCompAlgo` 3), to be put
    /// back in front of every frame read.
    case headerStripping(Data)
    /// Compressed with zlib (algorithm 0), bzlib (1) or LZO (2), or encoded more than once, none of
    /// which this reader undoes. mkvmerge 6.8 compressed every PGS subtitle track with zlib, seen
    /// 2026-11-20: an empty `ContentCompression`, whose algorithm defaults to zlib.
    case compressed(algorithm: UInt64)
    case encrypted

    /// Whether `MatroskaFile.frame(_:of:)` can hand out the frames as they were before encoding.
    public var isReadable: Bool {
        switch self {
        case .none, .headerStripping: true
        case .compressed, .encrypted: false
        }
    }
}

// MARK: - Reading a TrackEntry

extension MatroskaTrack {
    /// The track a `TrackEntry` element describes, or `nil` for one with no number, which no block
    /// could name.
    static func read(_ entry: EBMLElement, with reader: inout EBMLReader) throws -> MatroskaTrack? {
        var track = MatroskaTrack()
        var language: String?
        var languageBCP47: String?
        for child in try reader.children(of: entry) {
            switch child.id {
            case 0x22B59C: language = try reader.string(child)
            case 0x22B59D: languageBCP47 = try reader.string(child)
            case 0xE0: track.video = try readVideo(child, with: &reader)
            case 0xE1: track.audio = try readAudio(child, with: &reader)
            case 0x6D80: track.frameEncoding = try readEncodings(child, with: &reader)
            default:
                if try !track.readIdentity(child, with: &reader) {
                    try track.readCodec(child, with: &reader)
                }
            }
        }
        track.language = languageBCP47 ?? language ?? "eng"
        return track.number == 0 ? nil : track
    }

    /// The number, type, name and flags; `false` when `child` is none of them.
    private mutating func readIdentity(_ child: EBMLElement, with reader: inout EBMLReader) throws -> Bool {
        switch child.id {
        case 0xD7: number = try reader.unsigned(child) ?? 0
        case 0x73C5: uid = try reader.unsigned(child)
        case 0x83: kind = try Kind(reader.unsigned(child) ?? 0)
        case 0x536E: name = try reader.string(child)
        case 0xB9: isEnabled = try (reader.unsigned(child) ?? 1) != 0
        case 0x88: isDefault = try (reader.unsigned(child) ?? 1) != 0
        case 0x55AA: isForced = try (reader.unsigned(child) ?? 0) != 0
        default: return false
        }
        return true
    }

    /// The codec and its timing.
    private mutating func readCodec(_ child: EBMLElement, with reader: inout EBMLReader) throws {
        switch child.id {
        case 0x86: codecID = try reader.string(child) ?? ""
        case 0x63A2: codecPrivate = try reader.binary(child, limit: MatroskaFile.headElementLimit)
        case 0x258688: codecName = try reader.string(child)
        case 0x23E383: defaultDuration = try reader.unsigned(child)
        case 0x56AA: codecDelay = try reader.unsigned(child) ?? 0
        case 0x56BB: seekPreRoll = try reader.unsigned(child) ?? 0
        default: break
        }
    }

    private static func readVideo(_ element: EBMLElement, with reader: inout EBMLReader) throws -> Video {
        var video = Video()
        for child in try reader.children(of: element) {
            switch child.id {
            case 0xB0: video.pixelWidth = try reader.unsigned(child) ?? 0
            case 0xBA: video.pixelHeight = try reader.unsigned(child) ?? 0
            case 0x54B0: video.displayWidth = try reader.unsigned(child)
            case 0x54BA: video.displayHeight = try reader.unsigned(child)
            case 0x54B2: video.displayUnit = try reader.unsigned(child) ?? 0
            default: break
            }
        }
        return video
    }

    private static func readAudio(_ element: EBMLElement, with reader: inout EBMLReader) throws -> Audio {
        var audio = Audio()
        for child in try reader.children(of: element) {
            switch child.id {
            case 0xB5: audio.samplingFrequency = try reader.float(child) ?? 8000
            case 0x78B5: audio.outputSamplingFrequency = try reader.float(child)
            case 0x9F: audio.channels = try reader.unsigned(child) ?? 1
            case 0x6264: audio.bitDepth = try reader.unsigned(child)
            default: break
            }
        }
        return audio
    }

    /// One `ContentEncoding`, as far as deciding what a frame needs.
    private struct Encoding {
        var scope: UInt64 = 1
        var isEncryption = false
        var algorithm: UInt64 = 0
        var settings = Data()
    }

    /// What `ContentEncodings` amounts to. Only one header stripping over the frames alone is undone;
    /// anything stacked or applied to the codec's private data as well is named, not attempted.
    private static func readEncodings(
        _ element: EBMLElement,
        with reader: inout EBMLReader
    ) throws -> MatroskaFrameEncoding {
        var encodings: [Encoding] = []
        for entry in try reader.children(of: element) where entry.id == 0x6240 {
            encodings.append(try readEncoding(entry, with: &reader))
        }
        guard let first = encodings.first else { return .none }
        if encodings.contains(where: \.isEncryption) { return .encrypted }
        if encodings.count == 1, first.algorithm == 3, first.scope == 1 {
            return .headerStripping(first.settings)
        }
        return .compressed(algorithm: first.algorithm)
    }

    private static func readEncoding(_ element: EBMLElement, with reader: inout EBMLReader) throws -> Encoding {
        var encoding = Encoding()
        for child in try reader.children(of: element) {
            switch child.id {
            case 0x5032: encoding.scope = try reader.unsigned(child) ?? 1
            case 0x5033:
                let type = try reader.unsigned(child) ?? 0
                encoding.isEncryption = encoding.isEncryption || type == 1
            case 0x5035: encoding.isEncryption = true
            case 0x5034:
                for setting in try reader.children(of: child) {
                    if setting.id == 0x4254 { encoding.algorithm = try reader.unsigned(setting) ?? 0 }
                    if setting.id == 0x4255 {
                        encoding.settings = try reader.binary(
                            setting,
                            limit: MatroskaFile.headElementLimit
                        )
                    }
                }
            default: break
            }
        }
        return encoding
    }
}
