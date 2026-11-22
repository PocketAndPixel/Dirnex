import Foundation

/// H.264's network abstraction layer units as an AVI keeps them (PLAN.md §M42 ▸ Slice 5): each frame a
/// run of units behind start codes (ITU-T H.264 Annex B), where MP4 and Matroska put a length before
/// each and the parameter sets in a separate record. Core Media takes the second form only.
enum H264NALUnits {
    /// The units of `data` written behind three- or four-byte start codes, each without its start
    /// code or the zero bytes padding it from the next.
    static func annexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index + 3)
                index += 3
            } else {
                index += 1
            }
        }
        return starts.enumerated().compactMap { number, start in
            var end = number + 1 < starts.count ? starts[number + 1] - 3 : bytes.count
            while end > start, bytes[end - 1] == 0 {
                end -= 1
            }
            return end > start ? Data(bytes[start..<end]) : nil
        }
    }

    /// The units of `data` written behind `lengthSize`-byte big-endian lengths, or `nil` when a length
    /// runs past the end, which is how a frame in the other form reads.
    static func lengthPrefixed(_ data: Data, lengthSize: Int) -> [Data]? {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var index = 0
        while index < bytes.count {
            guard index + lengthSize <= bytes.count else { return nil }
            let length = bytes[index..<index + lengthSize].reduce(0) { $0 << 8 | Int($1) }
            index += lengthSize
            guard length > 0, index + length <= bytes.count else { return nil }
            units.append(Data(bytes[index..<index + length]))
            index += length
        }
        return units
    }

    /// `units` behind four-byte lengths, the form Core Media decodes.
    static func lengthPrefixed(_ units: [Data]) -> Data {
        var data = Data(capacity: units.reduce(0) { $0 + 4 + $1.count })
        for unit in units {
            let length = UInt32(unit.count)
            data.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
            data.append(unit)
        }
        return data
    }

    /// The unit's type: 1 a slice, 5 a slice of an IDR picture, 6 SEI, 7 and 8 the parameter sets,
    /// 9 an access unit delimiter.
    static func type(_ unit: Data) -> Int {
        unit.first.map { Int($0 & 0x1F) } ?? 0
    }

    /// The unit's payload after its header byte, with the emulation prevention bytes taken out: an
    /// encoder writes `00 00 03` wherever two zeros would otherwise be followed by a byte below 4.
    static func payload(_ unit: Data, limit: Int = .max) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in unit.dropFirst().prefix(limit) {
            if zeros >= 2, byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

extension ForwardBitReader {
    /// An unsigned Exp-Golomb code, `ue(v)` in H.264's syntax tables.
    mutating func readUnsignedGolomb() -> Int {
        var zeros = 0
        while read(1) == 0, !isExhausted, zeros < 32 {
            zeros += 1
        }
        return (1 << zeros) - 1 + read(zeros)
    }

    /// A signed Exp-Golomb code, `se(v)`.
    mutating func readSignedGolomb() -> Int {
        let code = readUnsignedGolomb()
        return code & 1 == 1 ? (code + 1) / 2 : -(code / 2)
    }
}

/// What a sequence parameter set says that this reader needs (ITU-T H.264 §7.3.2.1.1): enough to
/// find each picture's order and to write the decoder's configuration record.
public struct H264SequenceParameters: Equatable, Sendable {
    public var id = 0
    public var profile: UInt8 = 0
    public var constraints: UInt8 = 0
    public var level: UInt8 = 0
    public var chromaFormat = 1
    public var separateColourPlanes = false
    public var bitDepthLuma = 8
    public var bitDepthChroma = 8
    public var log2MaxFrameNumber = 4
    public var pictureOrderType = 0
    public var log2MaxPictureOrderLSB = 4
    public var deltaPictureOrderAlwaysZero = false
    public var offsetForNonReference = 0
    public var offsetTopToBottom = 0
    public var offsetsForReferenceFrames: [Int] = []
    public var frameMacroblocksOnly = true
    /// The picture as shown, its cropping taken off.
    public var width = 0
    public var height = 0
    /// How many pictures at most come before one that is shown earlier, when the encoder says
    /// (`max_num_reorder_frames`): x264 writes it; a stream without it is read with the most the
    /// standard allows.
    public var reorderDepth: Int?

    /// The profiles whose sequence parameter sets carry the chroma format and bit depths, and whose
    /// configuration records repeat them.
    static let highProfiles: Set<UInt8> = [
        100,
        110,
        122,
        244,
        44,
        83,
        86,
        118,
        128,
        138,
        139,
        134,
        135
    ]

    public init() {}

    /// The parameters in `unit`, a type 7 unit, or `nil` for anything else.
    public init?(_ unit: Data) {
        guard H264NALUnits.type(unit) == 7 else { return nil }
        var bits = ForwardBitReader(H264NALUnits.payload(unit, limit: 1024))
        profile = UInt8(bits.read(8))
        constraints = UInt8(bits.read(8))
        level = UInt8(bits.read(8))
        id = bits.readUnsignedGolomb()
        if Self.highProfiles.contains(profile) {
            chromaFormat = bits.readUnsignedGolomb()
            if chromaFormat == 3 { separateColourPlanes = bits.read(1) == 1 }
            bitDepthLuma = bits.readUnsignedGolomb() + 8
            bitDepthChroma = bits.readUnsignedGolomb() + 8
            _ = bits.read(1)
            if bits.read(1) == 1 {
                for list in 0..<(chromaFormat == 3 ? 12 : 8) where bits.read(1) == 1 {
                    Self.skipScalingList(&bits, size: list < 6 ? 16 : 64)
                }
            }
        }
        log2MaxFrameNumber = bits.readUnsignedGolomb() + 4
        pictureOrderType = bits.readUnsignedGolomb()
        if pictureOrderType == 0 {
            log2MaxPictureOrderLSB = bits.readUnsignedGolomb() + 4
        } else if pictureOrderType == 1 {
            deltaPictureOrderAlwaysZero = bits.read(1) == 1
            offsetForNonReference = bits.readSignedGolomb()
            offsetTopToBottom = bits.readSignedGolomb()
            let cycle = bits.readUnsignedGolomb()
            guard cycle <= 255 else { return nil }
            offsetsForReferenceFrames = (0..<cycle).map { _ in bits.readSignedGolomb() }
        }
        _ = bits.readUnsignedGolomb()
        _ = bits.read(1)
        readSize(&bits)
        guard !bits.isExhausted, pictureOrderType <= 2 else { return nil }
        // A usability section cut short loses only the reorder depth.
        if bits.read(1) == 1 { readUsability(&bits) }
    }

    private mutating func readSize(_ bits: inout ForwardBitReader) {
        let widthInMacroblocks = bits.readUnsignedGolomb() + 1
        let heightInMapUnits = bits.readUnsignedGolomb() + 1
        frameMacroblocksOnly = bits.read(1) == 1
        if !frameMacroblocksOnly { _ = bits.read(1) }
        _ = bits.read(1)
        let fieldFactor = frameMacroblocksOnly ? 1 : 2
        width = widthInMacroblocks * 16
        height = heightInMapUnits * 16 * fieldFactor
        guard bits.read(1) == 1 else { return }
        let crop = (0..<4).map { _ in bits.readUnsignedGolomb() }
        let monochrome = chromaFormat == 0 || separateColourPlanes
        let unitX = monochrome || chromaFormat == 3 ? 1 : 2
        let unitY = (monochrome || chromaFormat != 1 ? 1 : 2) * fieldFactor
        width -= (crop[0] + crop[1]) * unitX
        height -= (crop[2] + crop[3]) * unitY
    }

    /// The video usability information, read as far as `max_num_reorder_frames` (§E.1.1).
    private mutating func readUsability(_ bits: inout ForwardBitReader) {
        if bits.read(1) == 1, bits.read(8) == 255 { _ = bits.read(32) }
        if bits.read(1) == 1 { _ = bits.read(1) }
        if bits.read(1) == 1 {
            _ = bits.read(4)
            if bits.read(1) == 1 { _ = bits.read(24) }
        }
        if bits.read(1) == 1 {
            _ = bits.readUnsignedGolomb()
            _ = bits.readUnsignedGolomb()
        }
        if bits.read(1) == 1 { _ = bits.read(65) }
        let networkHRD = bits.read(1) == 1
        if networkHRD { Self.skipHypotheticalDecoder(&bits) }
        let codingHRD = bits.read(1) == 1
        if codingHRD { Self.skipHypotheticalDecoder(&bits) }
        if networkHRD || codingHRD { _ = bits.read(1) }
        _ = bits.read(1)
        guard bits.read(1) == 1 else { return }
        _ = bits.read(1)
        for _ in 0..<4 {
            _ = bits.readUnsignedGolomb()
        }
        let depth = bits.readUnsignedGolomb()
        if !bits.isExhausted { reorderDepth = depth }
    }

    private static func skipHypotheticalDecoder(_ bits: inout ForwardBitReader) {
        let count = bits.readUnsignedGolomb() + 1
        _ = bits.read(8)
        for _ in 0..<min(count, 32) {
            _ = bits.readUnsignedGolomb()
            _ = bits.readUnsignedGolomb()
            _ = bits.read(1)
        }
        _ = bits.read(20)
    }

    private static func skipScalingList(_ bits: inout ForwardBitReader, size: Int) {
        var last = 8
        var next = 8
        for _ in 0..<size {
            if next != 0 { next = (last + bits.readSignedGolomb() + 256) % 256 }
            last = next == 0 ? last : next
        }
    }
}

/// What a picture parameter set says that this reader needs (§7.3.2.2).
struct H264PictureParameters: Equatable, Sendable {
    let id: Int
    let sequenceID: Int
    let bottomFieldOrderPresent: Bool

    init?(_ unit: Data) {
        guard H264NALUnits.type(unit) == 8 else { return nil }
        var bits = ForwardBitReader(H264NALUnits.payload(unit, limit: 64))
        id = bits.readUnsignedGolomb()
        sequenceID = bits.readUnsignedGolomb()
        _ = bits.read(1)
        bottomFieldOrderPresent = bits.read(1) == 1
        guard !bits.isExhausted else { return nil }
    }
}

/// The decoder's configuration record for H.264 (ISO/IEC 14496-15 §5.3.3.1), the `avcC` atom an MP4
/// carries and an AVI leaves out.
enum H264Configuration {
    /// The record for one sequence and one picture parameter set, with four-byte lengths before each
    /// unit, and for the high profiles the chroma format and bit depths after them. Measured against
    /// the record Lavf wrote into the 1440p MP4 sample, from that file's own parameter sets.
    static func record(sequence: Data, picture: Data) -> Data? {
        guard let parameters = H264SequenceParameters(sequence), sequence.count <= 0xFFFF,
              picture.count <= 0xFFFF, sequence.count >= 4
        else { return nil }
        var record = Data(
            [1, parameters.profile, parameters.constraints, parameters.level, 0xFF, 0xE1]
        )
        record.append(contentsOf: [UInt8(sequence.count >> 8), UInt8(sequence.count & 0xFF)])
        record.append(sequence)
        record.append(contentsOf: [1, UInt8(picture.count >> 8), UInt8(picture.count & 0xFF)])
        record.append(picture)
        if [100, 110, 122, 144].contains(parameters.profile) {
            record.append(contentsOf: [
                0xFC | UInt8(parameters.chromaFormat & 3),
                0xF8 | UInt8((parameters.bitDepthLuma - 8) & 7),
                0xF8 | UInt8((parameters.bitDepthChroma - 8) & 7),
                0
            ])
        }
        return record
    }
}
