import Foundation

@testable import DirnexCore

/// Writes bits most significant first, with H.264's Exp-Golomb codes.
struct GolombBitWriter {
    private(set) var bytes: [UInt8] = []
    private var count = 0

    mutating func write(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            if count % 8 == 0 { bytes.append(0) }
            if value >> shift & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(count % 8) }
            count += 1
        }
    }

    mutating func flag(_ value: Bool) {
        write(value ? 1 : 0, bits: 1)
    }

    mutating func unsignedGolomb(_ value: Int) {
        let code = value + 1
        let length = Int.bitWidth - code.leadingZeroBitCount
        write(0, bits: length - 1)
        write(code, bits: length)
    }

    mutating func signedGolomb(_ value: Int) {
        unsignedGolomb(value > 0 ? 2 * value - 1 : -2 * value)
    }

    /// The RBSP stop bit and the zeros to the byte's end.
    mutating func finish() -> [UInt8] {
        write(1, bits: 1)
        while count % 8 != 0 {
            write(0, bits: 1)
        }
        return bytes
    }
}

/// Writes H.264 units for the picture order tests (PLAN.md §M42 ▸ Slice 5): parameter sets and the
/// head of a slice, enough for `H264PictureOrder`, with emulation prevention as an encoder adds it.
enum H264TestWriter {
    struct Sequence {
        var profile: UInt8 = 66
        var pictureOrderType = 0
        var log2MaxFrameNumber = 4
        var log2MaxOrderLSB = 4
        var frameMacroblocksOnly = true
        var alwaysZero = false
        var offsetForNonReference = 0
        var offsetTopToBottom = 0
        var cycle: [Int] = []
        var reorderDepth: Int?
        var widthInMacroblocks = 20
        var heightInMapUnits = 15
        /// Left, right, top and bottom, in crop units.
        var crop: [Int]?
    }

    static func unit(header: UInt8, _ payload: [UInt8]) -> Data {
        var out: [UInt8] = [header]
        var zeros = 0
        for byte in payload {
            if zeros >= 2, byte <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    static func sequence(_ sequence: Sequence = Sequence()) -> Data {
        var bits = GolombBitWriter()
        bits.write(Int(sequence.profile), bits: 8)
        bits.write(0, bits: 8)
        bits.write(30, bits: 8)
        bits.unsignedGolomb(0)
        if H264SequenceParameters.highProfiles.contains(sequence.profile) {
            bits.unsignedGolomb(1)
            bits.unsignedGolomb(0)
            bits.unsignedGolomb(0)
            bits.flag(false)
            bits.flag(false)
        }
        bits.unsignedGolomb(sequence.log2MaxFrameNumber - 4)
        bits.unsignedGolomb(sequence.pictureOrderType)
        if sequence.pictureOrderType == 0 {
            bits.unsignedGolomb(sequence.log2MaxOrderLSB - 4)
        } else if sequence.pictureOrderType == 1 {
            bits.flag(sequence.alwaysZero)
            bits.signedGolomb(sequence.offsetForNonReference)
            bits.signedGolomb(sequence.offsetTopToBottom)
            bits.unsignedGolomb(sequence.cycle.count)
            for offset in sequence.cycle {
                bits.signedGolomb(offset)
            }
        }
        bits.unsignedGolomb(4)
        bits.flag(false)
        bits.unsignedGolomb(sequence.widthInMacroblocks - 1)
        bits.unsignedGolomb(sequence.heightInMapUnits - 1)
        bits.flag(sequence.frameMacroblocksOnly)
        if !sequence.frameMacroblocksOnly { bits.flag(false) }
        bits.flag(true)
        bits.flag(sequence.crop != nil)
        if let crop = sequence.crop {
            for value in crop {
                bits.unsignedGolomb(value)
            }
        }
        bits.flag(sequence.reorderDepth != nil)
        if let depth = sequence.reorderDepth {
            for _ in 0..<8 {
                bits.flag(false)
            }
            bits.flag(true)
            bits.flag(true)
            for value in [0, 0, 16, 16, depth, depth + 1] {
                bits.unsignedGolomb(value)
            }
        }
        return unit(header: 0x67, bits.finish())
    }

    static func picture(bottomFieldOrderPresent: Bool = false) -> Data {
        var bits = GolombBitWriter()
        bits.unsignedGolomb(0)
        bits.unsignedGolomb(0)
        bits.flag(false)
        bits.flag(bottomFieldOrderPresent)
        bits.unsignedGolomb(0)
        return unit(header: 0x68, bits.finish())
    }

    /// The head of a slice: `type` 0 P, 1 B, 2 I. `bottomField` is `nil` for a frame, else which field
    /// of a field picture.
    static func slice(
        _ sequence: Sequence = Sequence(),
        idr: Bool = false,
        reference: Bool = true,
        type: Int,
        frameNumber: Int = 0,
        orderLSB: Int = 0,
        bottomField: Bool? = nil,
        deltaBottom: Int? = nil,
        delta: (Int, Int?)? = nil
    ) -> Data {
        var bits = GolombBitWriter()
        bits.unsignedGolomb(0)
        bits.unsignedGolomb(type + 5)
        bits.unsignedGolomb(0)
        bits.write(frameNumber, bits: sequence.log2MaxFrameNumber)
        if !sequence.frameMacroblocksOnly {
            bits.flag(bottomField != nil)
            if let bottomField { bits.flag(bottomField) }
        }
        if idr { bits.unsignedGolomb(0) }
        if sequence.pictureOrderType == 0 {
            bits.write(orderLSB, bits: sequence.log2MaxOrderLSB)
            if let deltaBottom { bits.signedGolomb(deltaBottom) }
        } else if sequence.pictureOrderType == 1, !sequence.alwaysZero, let delta {
            bits.signedGolomb(delta.0)
            if let second = delta.1 { bits.signedGolomb(second) }
        }
        bits.unsignedGolomb(0)
        let header: UInt8 = (reference ? 0x60 : 0) | (idr ? 5 : 1)
        return unit(header: header, bits.finish() + [0x80, 0x11, 0x22])
    }

    /// `units` behind four-byte start codes, as an AVI chunk holds them.
    static func annexB(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { $0 += [0, 0, 0, 1] + $1 }
    }
}
