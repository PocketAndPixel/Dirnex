import Foundation

/// One stream of an AVI, from its `strl` list (PLAN.md §M42 ▸ Slice 5): what kind it is, its clock,
/// and its format (`strf`), a `BITMAPINFOHEADER` for a picture and a `WAVEFORMATEX` for a sound.
public struct AVIStream: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case video
        case audio
        case text
        case other(String)
    }

    public struct Video: Equatable, Sendable {
        public var width = 0
        public var height = 0
        public var bitCount = 0
        /// The compression code (`biCompression`): `H264`, `XVID`, `MJPG`.
        public var compression = ""

        public init() {}
    }

    public struct Audio: Equatable, Sendable {
        /// The format tag, the real one for `WAVE_FORMAT_EXTENSIBLE`, which keeps it in its subformat.
        public var formatTag: UInt16 = 0
        public var channels = 0
        public var sampleRate = 0
        public var averageBytesPerSecond = 0
        public var blockAlign = 0
        public var bitsPerSample = 0

        public init() {}
    }

    /// The stream's number, which its chunks' names start with (`01wb` for stream 1).
    public var number = 0
    public var kind: Kind = .other("")
    public var handler = ""
    public var flags: UInt32 = 0
    /// The stream's clock: each tick lasts `scale / rate` seconds, and it starts at tick `start`.
    public var scale: UInt32 = 0
    public var rate: UInt32 = 0
    public var start: UInt32 = 0
    /// Its length in ticks.
    public var length: UInt32 = 0
    /// Bytes in a tick for a sound stored at a constant rate, which is then timed by its bytes; 0 for
    /// one stored a frame to a chunk, timed by its chunks.
    public var sampleSize: UInt32 = 0
    public var name: String?
    public var video: Video?
    public var audio: Audio?
    /// What follows the format's fixed header: an H.264 configuration, MPEG-4's headers, an
    /// `AudioSpecificConfig`.
    public var extraData = Data()
    /// The OpenDML super index, when there is one (`indx`).
    var superIndex: [AVISuperIndexEntry] = []
    /// A standard index kept in `indx` itself, as a few writers do.
    var inlineIndex: Data?

    public init() {}

    /// Whether a player should leave it alone (`AVISF_DISABLED`).
    public var isEnabled: Bool { flags & 1 == 0 }

    /// Seconds in one tick, or `nil` for a stream whose clock is not stated.
    public var tickSeconds: Double? {
        guard scale > 0, rate > 0 else { return nil }
        return Double(scale) / Double(rate)
    }

    public var durationSeconds: Double? {
        guard let tick = tickSeconds, length > 0 else { return nil }
        return Double(length) * tick
    }

    /// The four-character code stream `number`'s chunks start with.
    var chunkPrefix: String {
        String(format: "%02d", number)
    }
}

/// One entry of an OpenDML super index: where a standard index chunk is, and how many ticks it covers.
struct AVISuperIndexEntry: Equatable, Sendable {
    let offset: UInt64
    let size: UInt32
    let duration: UInt32
}

/// The `hdrl` list: the main header, each stream's list, and OpenDML's extended header.
struct AVIHeaderList {
    var main = AVIMainHeader()
    var streams: [AVIStream] = []
    var totalFrames: UInt32?

    init(_ data: Data) throws {
        let source = DataByteSource(data)
        try AVIFile.walk(source, from: 0, to: source.length) { chunk in
            let body = try source.read(
                at: chunk.dataOffset,
                count: Int(chunk.end - chunk.dataOffset)
            )
            switch (chunk.id, chunk.listType) {
            case ("avih", _):
                guard body.count >= 40 else { throw AVIError.malformed(offset: chunk.offset) }
                main.microsecondsPerFrame = RIFFBytes.uint32(body, at: 0)
                main.flags = RIFFBytes.uint32(body, at: 12)
                main.totalFrames = RIFFBytes.uint32(body, at: 16)
                main.streamCount = RIFFBytes.uint32(body, at: 24)
                main.width = RIFFBytes.uint32(body, at: 32)
                main.height = RIFFBytes.uint32(body, at: 36)
            case ("LIST", "strl"):
                var stream = try Self.stream(body.dropFirst(4))
                stream.number = streams.count
                streams.append(stream)
            case ("LIST", "odml"):
                let inner = DataByteSource(Data(body.dropFirst(4)))
                try AVIFile.walk(inner, from: 0, to: inner.length) { chunk in
                    if chunk.id == "dmlh" {
                        totalFrames = RIFFBytes.uint32(
                            try inner.read(at: chunk.dataOffset, count: 4),
                            at: 0
                        )
                    }
                    return true
                }
            default:
                break
            }
            return true
        }
        guard !streams.isEmpty else { throw AVIError.truncated }
    }

    private static func stream(_ list: Data) throws -> AVIStream {
        var stream = AVIStream()
        let source = DataByteSource(Data(list))
        var format: Data?
        try AVIFile.walk(source, from: 0, to: source.length) { chunk in
            let body = try source.read(
                at: chunk.dataOffset,
                count: Int(chunk.end - chunk.dataOffset)
            )
            switch chunk.id {
            case "strh":
                guard body.count >= 48 else { throw AVIError.malformed(offset: chunk.offset) }
                stream.kind = switch RIFFBytes.fourCC(body, at: 0) {
                case "vids": .video
                case "auds": .audio
                case "txts": .text
                case let other: .other(other)
                }
                stream.handler = RIFFBytes.fourCC(body, at: 4)
                stream.flags = RIFFBytes.uint32(body, at: 8)
                stream.scale = RIFFBytes.uint32(body, at: 20)
                stream.rate = RIFFBytes.uint32(body, at: 24)
                stream.start = RIFFBytes.uint32(body, at: 28)
                stream.length = RIFFBytes.uint32(body, at: 32)
                stream.sampleSize = RIFFBytes.uint32(body, at: 44)
            case "strf":
                format = body
            case "strn":
                let text = body.prefix { $0 != 0 }
                stream.name = String(data: text, encoding: .utf8) ?? String(
                    data: text,
                    encoding: .isoLatin1
                )
            case "indx":
                readIndex(body, into: &stream)
            default:
                break
            }
            return true
        }
        if let format { readFormat(format, into: &stream) }
        return stream
    }

    private static func readFormat(_ body: Data, into stream: inout AVIStream) {
        switch stream.kind {
        case .video where body.count >= 40:
            var video = AVIStream.Video()
            video.width = Int(abs(RIFFBytes.int32(body, at: 4)))
            video.height = Int(abs(RIFFBytes.int32(body, at: 8)))
            video.bitCount = Int(RIFFBytes.uint16(body, at: 14))
            video.compression = RIFFBytes.fourCC(body, at: 16)
            let headerSize = max(40, min(Int(RIFFBytes.uint32(body, at: 0)), body.count))
            stream.extraData = Data(body.dropFirst(headerSize))
            stream.video = video
        case .audio where body.count >= 16:
            var audio = AVIStream.Audio()
            audio.formatTag = RIFFBytes.uint16(body, at: 0)
            audio.channels = Int(RIFFBytes.uint16(body, at: 2))
            audio.sampleRate = Int(RIFFBytes.uint32(body, at: 4))
            audio.averageBytesPerSecond = Int(RIFFBytes.uint32(body, at: 8))
            audio.blockAlign = Int(RIFFBytes.uint16(body, at: 12))
            audio.bitsPerSample = Int(RIFFBytes.uint16(body, at: 14))
            if body.count >= 18 {
                let extraSize = min(Int(RIFFBytes.uint16(body, at: 16)), body.count - 18)
                stream.extraData = Data(body.dropFirst(18).prefix(extraSize))
            }
            // WAVE_FORMAT_EXTENSIBLE keeps the real tag in the first two bytes of its subformat.
            if audio.formatTag == 0xFFFE, stream.extraData.count >= 8 {
                audio.formatTag = RIFFBytes.uint16(stream.extraData, at: 6)
            }
            stream.audio = audio
        default:
            break
        }
    }

    /// An `indx` chunk: a super index (type 0) listing standard index chunks, or a standard index
    /// (type 1) kept there itself.
    private static func readIndex(_ body: Data, into stream: inout AVIStream) {
        guard body.count >= 24 else { return }
        let longsPerEntry = Int(RIFFBytes.uint16(body, at: 0))
        let type = body[body.startIndex + 3]
        let count = Int(RIFFBytes.uint32(body, at: 4))
        if type == 1 {
            stream.inlineIndex = body
            return
        }
        guard type == 0, longsPerEntry >= 4 else { return }
        let step = longsPerEntry * 4
        stream.superIndex = (0..<count).compactMap { index in
            let at = 24 + index * step
            guard at + 16 <= body.count else { return nil }
            let entry = AVISuperIndexEntry(
                offset: RIFFBytes.uint64(body, at: at),
                size: RIFFBytes.uint32(body, at: at + 8),
                duration: RIFFBytes.uint32(body, at: at + 12)
            )
            return entry.offset == 0 ? nil : entry
        }
    }
}
