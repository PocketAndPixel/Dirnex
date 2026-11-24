import Foundation

/// Why a DTS frame could not be decoded.
public enum DTSError: Error, Equatable, Sendable {
    /// No core sync word at the frame's start, in any of the four ways DTS is stored.
    case notDTS
    /// The frame ends before what its header says it holds.
    case truncated
    /// A value the specification leaves invalid, or a check word that does not match.
    case invalid(String)
    /// A frame this decoder does not decode: more than five primary channels, or an encoder revision
    /// the specification says to mute.
    case unsupported(String)
}

/// A DTS Coherent Acoustics core frame's bit-stream header (ETSI TS 102 114 §5.4.2): how long the
/// frame is, how many samples it carries, and the channels, rate and filter it was coded with.
public struct DTSCoreHeader: Equatable, Sendable {
    /// `FTYPE` 0: a frame cut short to end with a picture.
    public var isTermination: Bool
    /// `CPF`: CRC words are present, after the header and after each subframe's side information.
    public var hasCRC: Bool
    /// `NBLKS + 1`: blocks of 32 samples per channel.
    public var blocks: Int
    /// `FSIZE + 1`: the frame's bytes, core and core extensions.
    public var frameSize: Int
    /// `AMODE`: which primary channels the frame carries (Table 5-4).
    public var audioMode: Int
    public var sampleRate: Int
    /// `RATE`: 29 is the lossless quantizer's step sizes.
    public var rateCode: Int
    public var hasDynamicRange: Bool
    public var hasTimestamp: Bool
    public var hasAuxiliaryData: Bool
    /// `EXT_AUDIO` and `EXT_AUDIO_ID`: an extension follows the core (XCh, X96 or XXCh).
    public var extensionID: Int?
    /// `ASPF`: a `DSYNC` word ends every subsubframe rather than every subframe.
    public var syncEverySubsubframe: Bool
    /// `LFF`: the LFE channel's interpolation, 128 or 64, or `nil` without one.
    public var lfeInterpolation: Int?
    /// `HFLAG`: prediction continues from the frame before.
    public var continuesPrediction: Bool
    /// `FILTS`: the perfect-reconstruction synthesis filter rather than the other.
    public var perfectReconstruction: Bool
    /// `VERNUM`.
    public var encoderVersion: Int
    /// `SUMF` and `SUMS`: front and surround pairs coded as sum and difference.
    public var frontSumDifference: Bool
    public var surroundSumDifference: Bool

    /// Samples per channel the frame decodes to.
    public var samples: Int { blocks * 32 }

    /// The primary channels `AMODE` names, in the order the frame carries them; `nil` past 5.
    public var primaryChannels: Int? {
        let counts = [1, 2, 2, 2, 2, 3, 3, 4, 4, 5]
        return audioMode < counts.count ? counts[audioMode] : nil
    }

    /// The layout the decoder plays this frame in.
    public var layout: DTSChannelLayout? {
        DTSChannelLayout(audioMode: audioMode, hasLFE: lfeInterpolation != nil)
    }

    static let sampleRates = [
        0,
        8000,
        16000,
        32000,
        0,
        0,
        11025,
        22050,
        44100,
        0,
        0,
        12000,
        24000,
        48000
    ]

    /// Reads the header from `reader`, which is left at the primary audio coding header.
    static func read(_ reader: inout DTSBitReader) throws -> DTSCoreHeader {
        guard try reader.bits(32) == 0x7FFE_8001 else { throw DTSError.notDTS }
        let frameType = try reader.bits(1)
        _ = try reader.bits(5) // SHORT, which a decoder pads to whole blocks anyway
        let crc = try reader.bit()
        let blocks = try reader.bits(7) + 1
        let size = try reader.bits(14) + 1
        let mode = try reader.bits(6)
        let rateIndex = try reader.bits(4)
        let rate = try reader.bits(5)
        _ = try reader.bits(1) // FixedBit
        let dynamicRange = try reader.bit()
        let timestamp = try reader.bit()
        let auxiliary = try reader.bit()
        _ = try reader.bits(1) // HDCD
        let extensionID = try reader.bits(3)
        let hasExtension = try reader.bit()
        let sync = try reader.bit()
        let lfe = try reader.bits(2)
        let history = try reader.bit()
        if crc == 1 { _ = try reader.bits(16) }
        let filter = try reader.bit()
        let version = try reader.bits(4)
        _ = try reader.bits(2) // CHIST
        _ = try reader.bits(3) // PCMR
        let sumFront = try reader.bit()
        let sumSurround = try reader.bit()
        _ = try reader.bits(4) // DIALNORM, which no player of a preview applies

        guard blocks >= 6, size >= 96 else { throw DTSError.invalid(
            "frame of \(blocks) blocks, \(size) bytes"
        ) }
        guard rateIndex < sampleRates.count, sampleRates[rateIndex] > 0 else {
            throw DTSError.invalid("sample rate index \(rateIndex)")
        }
        guard lfe != 3 else { throw DTSError.invalid("LFF 3") }
        return DTSCoreHeader(
            isTermination: frameType == 0,
            hasCRC: crc == 1,
            blocks: blocks,
            frameSize: size,
            audioMode: mode,
            sampleRate: sampleRates[rateIndex],
            rateCode: rate,
            hasDynamicRange: dynamicRange == 1,
            hasTimestamp: timestamp == 1,
            hasAuxiliaryData: auxiliary == 1,
            extensionID: hasExtension == 1 ? extensionID : nil,
            syncEverySubsubframe: sync == 1,
            lfeInterpolation: lfe == 0 ? nil : lfe == 1 ? 128 : 64,
            continuesPrediction: history == 1,
            perfectReconstruction: filter == 1,
            encoderVersion: version,
            frontSumDifference: sumFront == 1,
            surroundSumDifference: sumSurround == 1
        )
    }
}

extension DTSCoreHeader {
    /// The header of the frame at the start of `bytes`, in any of DTS's four storage forms, or `nil`
    /// where none starts there.
    public init?(_ bytes: Data) {
        guard let frame = DTSCoreFrame(bytes), let header = try? frame.header() else { return nil }
        self = header
    }
}

/// How the decoder lays out a frame's channels for playback: the order it writes them in, and the
/// Core Audio layout that order is (`AudioChannelLayoutTag`, written here as its number, since the
/// core keeps to bytes). Each order is the one a standard layout names, so nothing is mixed: DTS's
/// own order (centre first) is only rearranged.
public struct DTSChannelLayout: Equatable, Sendable {
    /// For each output channel, the primary channel it comes from, or `nil` for the LFE.
    public let sources: [Int?]
    /// The `AudioChannelLayoutTag` that names this order.
    public let tag: UInt32

    public var channels: Int { sources.count }

    /// The layout for `AMODE` 0 to 9, with or without the LFE channel; `nil` for the arrangements of
    /// more than five primary channels, which a core frame does not carry whole.
    public init?(audioMode: Int, hasLFE: Bool) {
        // Tags from CoreAudioBaseTypes.h: (n << 16) | channels.
        func tag(_ number: UInt32, _ channels: UInt32) -> UInt32 { number << 16 | channels }
        switch (audioMode, hasLFE) {
        // A (mono): as itself, or with the LFE as left, right and LFE, the mono in both.
        case (0, false): (sources, self.tag) = ([0], tag(100, 1)) // Mono
        case (0, true): (sources, self.tag) = ([0, 0, nil], tag(133, 3)) // DVD_4: L R LFE
        // A + B, L + R, sum and difference (decoded to L + R), Lt + Rt.
        case (1...4, false): (sources, self.tag) = ([0, 1], tag(101, 2)) // Stereo
        case (1...4, true): (sources, self.tag) = ([0, 1, nil], tag(133, 3)) // DVD_4: L R LFE
        // C + L + R.
        case (5, false): (sources, self.tag) = ([1, 2, 0], tag(113, 3)) // MPEG_3_0_A: L R C
        case (5, true): (sources, self.tag) = ([1, 2, 0, nil], tag(136, 4)) // DVD_10: L R C LFE
        // L + R + S.
        case (6, false): (sources, self.tag) = ([0, 1, 2], tag(131, 3)) // ITU_2_1: L R Cs
        case (6, true): (sources, self.tag) = ([0, 1, nil, 2], tag(134, 4)) // DVD_5: L R LFE Cs
        // C + L + R + S.
        case (7, false): (sources, self.tag) = ([1, 2, 0, 3], tag(115, 4)) // MPEG_4_0_A: L R C Cs
        case (7, true): (sources, self.tag) = ([1, 2, 0, nil, 3], tag(137, 5)) // DVD_11: L R C LFE Cs
        // L + R + SL + SR.
        case (8, false): (sources, self.tag) = ([0, 1, 2, 3], tag(108, 4)) // Quadraphonic
        case (8, true): (sources, self.tag) = ([0, 1, nil, 2, 3], tag(135, 5)) // DVD_6: L R LFE Ls Rs
        // C + L + R + SL + SR.
        case (9, false): (sources, self.tag) = ([1, 2, 0, 3, 4], tag(117, 5)) // MPEG_5_0_A
        case (9, true): (sources, self.tag) = ([1, 2, 0, nil, 3, 4], tag(121, 6)) // MPEG_5_1_A
        default: return nil
        }
    }
}

/// A frame's bytes in the form the decoder reads: 16-bit words, most significant byte first.
///
/// DTS is stored four ways (ETSI TS 102 114 §5.3, and the 14-bit forms of DTS on CD): 16-bit words
/// big- or little-endian, and 14 bits to each 16-bit word, either way round. Matroska and MP4 hold the
/// first; a WAV file or an AVI can hold any.
struct DTSCoreFrame {
    let bytes: [UInt8]

    init?(_ data: Data) {
        let head = [UInt8](data.prefix(4))
        guard head.count == 4 else { return nil }
        switch (head[0], head[1], head[2], head[3]) {
        case (0x7F, 0xFE, 0x80, 0x01): bytes = [UInt8](data)
        case (0xFE, 0x7F, 0x01, 0x80): bytes = Self.words(data, littleEndian: true, fourteen: false)
        case (0x1F, 0xFF, 0xE8, 0x00): bytes = Self.words(data, littleEndian: false, fourteen: true)
        case (0xFF, 0x1F, 0x00, 0xE8): bytes = Self.words(data, littleEndian: true, fourteen: true)
        default: return nil
        }
    }

    func header() throws -> DTSCoreHeader {
        var reader = DTSBitReader(bytes)
        return try DTSCoreHeader.read(&reader)
    }

    /// `data` as big-endian 16-bit words, each 14-bit word's bits packed up against the next.
    private static func words(_ data: Data, littleEndian: Bool, fourteen: Bool) -> [UInt8] {
        let raw = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var accumulator: UInt32 = 0
        var held = 0
        var index = 0
        while index + 1 < raw.count {
            let word = littleEndian
                ? UInt32(raw[index + 1]) << 8 | UInt32(raw[index])
                : UInt32(raw[index]) << 8 | UInt32(raw[index + 1])
            index += 2
            if !fourteen {
                out.append(UInt8(word >> 8))
                out.append(UInt8(word & 0xFF))
                continue
            }
            accumulator = accumulator << 14 | (word & 0x3FFF)
            held += 14
            while held >= 8 {
                held -= 8
                out.append(UInt8((accumulator >> UInt32(held)) & 0xFF))
            }
            accumulator &= (1 << UInt32(held)) - 1
        }
        return out
    }
}

/// Reads a frame's fields, most significant bit first.
struct DTSBitReader {
    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count * 8 - position }

    /// The next `count` bits, up to 32, as an unsigned value.
    mutating func bits(_ count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        guard position + count <= bytes.count * 8 else { throw DTSError.truncated }
        var value = 0
        var left = count
        while left > 0 {
            let offset = position & 7
            let take = min(8 - offset, left)
            let byte = Int(bytes[position >> 3])
            value = (value << take) | ((byte >> (8 - offset - take)) & ((1 << take) - 1))
            position += take
            left -= take
        }
        return value
    }

    mutating func bit() throws -> Int {
        guard position < bytes.count * 8 else { throw DTSError.truncated }
        let value = Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return value
    }

    /// The next `count` bits as a two's-complement value.
    mutating func signed(_ count: Int) throws -> Int {
        let value = try bits(count)
        return value >= 1 << (count - 1) ? value - (1 << count) : value
    }
}
