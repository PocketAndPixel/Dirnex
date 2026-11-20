import Foundation

/// How many frames of sound a packet holds, for the codecs whose packets differ (PLAN.md §M42 ▸
/// Slice 4). A Core Media sample buffer is as long as its packets say, so a packet that does not say
/// leaves the buffer with no length; the decoders themselves need no count (measured 2026-11-20 over a
/// WebM's Vorbis and a Steam clip's Opus: the same output with and without).
public enum MediaFrameCounter: Equatable, Sendable {
    case opus
    case vorbis(VorbisHeaders)

    /// The counter for `track`, or `nil` for a codec whose packets all last the same, or whose packets
    /// this cannot read.
    public init?(_ track: MatroskaTrack) {
        switch track.codecID {
        case "A_OPUS": self = .opus
        case "A_VORBIS":
            guard let codecPrivate = track.codecPrivate, let headers = VorbisHeaders(
                codecPrivate: codecPrivate
            )
            else { return nil }
            self = .vorbis(headers)
        default: return nil
        }
    }

    /// Frames in `packet`, given the block size of the packet before it, which Vorbis needs; the
    /// second value is this packet's block size for the next. `nil` for a packet that is not one.
    public func frames(in packet: Data, previousBlock: Int?) -> (frames: Int, block: Int?)? {
        switch self {
        case .opus: OpusPacket.frames(packet).map { ($0, nil) }
        case let .vorbis(headers): headers.frames(in: packet, previousBlock: previousBlock)
        }
    }
}

/// Opus's table of contents (RFC 6716 §3.1): what each packet's first byte, and for code 3 its second,
/// say of its length.
public enum OpusPacket {
    /// Frames at 48 kHz in `packet`, or `nil` for an empty packet or one longer than the 120 ms the RFC
    /// allows.
    public static func frames(_ packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let configuration = Int(toc >> 3)
        let frameSize = switch configuration {
        case 0..<12: [480, 960, 1920, 2880][configuration % 4]
        case 12..<16: [480, 960][configuration % 2]
        default: [120, 240, 480, 960][configuration % 4]
        }
        let count: Int
        switch toc & 0b11 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        let total = frameSize * count
        return total > 0 && total <= 5760 ? total : nil
    }
}

/// Vorbis's three header packets, as Matroska's private data laces them, and what they say of each
/// audio packet's length: its mode's block size and the block before it (Vorbis I §4.3.1).
public struct VorbisHeaders: Equatable, Sendable {
    /// The short and long block sizes, from the identification header.
    public let blockSizes: (short: Int, long: Int)
    /// Whether each mode uses the long block, from the end of the setup header.
    public let modeIsLong: [Bool]

    public static func == (lhs: VorbisHeaders, rhs: VorbisHeaders) -> Bool {
        lhs.blockSizes == rhs.blockSizes && lhs.modeIsLong == rhs.modeIsLong
    }

    /// The headers in `codecPrivate`: a count less one, Xiph-laced sizes of the first two, then the
    /// three packets.
    public init?(codecPrivate: Data) {
        guard let packets = Self.unlace(codecPrivate), packets.count == 3 else { return nil }
        self.init(identification: packets[0], setup: packets[2])
    }

    init?(identification: Data, setup: Data) {
        let id = [UInt8](identification)
        guard id.count >= 30, id[0] == 1, Array(id[1...6]) == Array("vorbis".utf8),
              setup.first == 5
        else { return nil }
        let short = 1 << Int(id[28] & 0x0F)
        let long = 1 << Int(id[28] >> 4)
        guard short <= long, (64...8192).contains(short), (64...8192).contains(long),
              let modes = Self.modes(setup: setup)
        else { return nil }
        blockSizes = (short, long)
        modeIsLong = modes
    }

    /// Frames from an audio packet: a quarter of the block before it and a quarter of its own.
    func frames(in packet: Data, previousBlock: Int?) -> (frames: Int, block: Int?)? {
        guard let first = packet.first, first & 1 == 0 else { return nil }
        let bits = Self.integerLog(modeIsLong.count - 1)
        let mode = Int(first >> 1) & ((1 << bits) - 1)
        guard mode < modeIsLong.count else { return nil }
        let current = modeIsLong[mode] ? blockSizes.long : blockSizes.short
        var previous = previousBlock ?? blockSizes.short
        // A long block says which window came before it, in the bit after its mode.
        if modeIsLong[mode] {
            previous = (Int(first) >> (1 + bits)) & 1 == 1 ? blockSizes.long : blockSizes.short
        }
        return ((previous + current) / 4, current)
    }

    /// The number of bits a value up to `value` takes (Vorbis I §9.2.1): 0 for 0, 1 for 1, 2 for 2–3.
    static func integerLog(_ value: Int) -> Int {
        value <= 0 ? 0 : Int.bitWidth - value.leadingZeroBitCount
    }

    /// The modes' block flags, found from the end of the setup header as FFmpeg's parser finds them:
    /// the setup header holds codebooks, floors and residues of variable size before the modes, which
    /// only a whole decoder would walk, while the modes and the framing bit close it.
    ///
    /// Read backwards, the stream is the framing bit, then for each mode from the last its 8-bit
    /// mapping, two 16-bit fields that must be zero and its block flag, then the 6-bit mode count less
    /// one. The count is the one where that 6-bit value agrees.
    static func modes(setup: Data) -> [Bool]? {
        var bits = ReverseBitReader([UInt8](setup))
        while bits.remaining > 97 {
            if bits.read(1) == 1 { break }
        }
        guard bits.remaining > 0 else { return nil }
        let framingEnd = bits.position
        var count = 0
        var agreed = 0
        while bits.remaining >= 97 {
            guard bits.read(8) <= 63, bits.read(16) == 0, bits.read(16) == 0 else { break }
            _ = bits.read(1)
            count += 1
            if count > 64 { break }
            let mark = bits.position
            if bits.remaining >= 6, bits.read(6) == count - 1 { agreed = count }
            bits.position = mark
        }
        guard agreed > 0 else { return nil }
        bits.position = framingEnd
        var flags = [Bool](repeating: false, count: agreed)
        for index in stride(from: agreed - 1, through: 0, by: -1) {
            _ = bits.read(40)
            flags[index] = bits.read(1) == 1
        }
        return flags
    }

    /// Xiph lacing: a count less one, then each size but the last as runs of 255 ended by a smaller
    /// byte.
    static func unlace(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return nil }
        var index = 1
        var sizes: [Int] = []
        for _ in 0..<Int(first) {
            var size = 0
            while true {
                guard index < bytes.count else { return nil }
                let byte = bytes[index]
                index += 1
                size += Int(byte)
                if byte != 255 { break }
            }
            sizes.append(size)
        }
        var packets: [Data] = []
        for size in sizes {
            guard size <= bytes.count - index else { return nil }
            packets.append(Data(bytes[index..<index + size]))
            index += size
        }
        packets.append(Data(bytes[index...]))
        return packets
    }
}

/// Reads a Vorbis packet's bits from its end towards its start. Vorbis packs each field's bits from
/// the least significant up, so reading the bytes in reverse, most significant bit first, gives each
/// field back whole and in reverse order.
struct ReverseBitReader {
    let bytes: [UInt8]
    var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count * 8 - position }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            guard position < bytes.count * 8 else { return value }
            let byte = bytes[bytes.count - 1 - position / 8]
            value = value << 1 | Int(byte >> (7 - position % 8) & 1)
            position += 1
        }
        return value
    }
}
