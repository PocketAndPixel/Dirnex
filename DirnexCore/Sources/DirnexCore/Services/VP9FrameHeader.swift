import Foundation

/// What a VP9 key frame's uncompressed header says of the stream (VP9 bitstream specification §6.2):
/// its profile, bit depth, colour space and chroma subsampling (PLAN.md §M42 ▸ Slice 4).
///
/// The system's VP9 decoder wants these in a `vpcC` record, which an MP4 carries and Matroska does
/// not: a WebM's `CodecPrivate` for VP9 is optional and was absent from all 23 seen on this Mac, so
/// the record is made from the first key frame, as FFmpeg does when it writes a WebM into an MP4.
public struct VP9FrameHeader: Equatable, Sendable {
    public let profile: Int
    public let bitDepth: Int
    /// `color_space`: 0 unknown, 1 BT.601, 2 BT.709, 3 SMPTE 170, 4 SMPTE 240, 5 BT.2020, 7 RGB.
    public let colorSpace: Int
    public let isFullRange: Bool
    public let subsamplingX: Bool
    public let subsamplingY: Bool

    /// The header at the start of `frame`, or `nil` when it is not a key frame's: an inter frame, a
    /// frame that only repeats one shown before, or bytes that are no VP9 frame at all.
    public init?(_ frame: Data) {
        var bits = ForwardBitReader([UInt8](frame.prefix(16)))
        guard bits.read(2) == 2 else { return nil }
        let low = bits.read(1)
        profile = bits.read(1) << 1 | low
        if profile == 3 { _ = bits.read(1) }
        // show_existing_frame, then frame_type, which is 0 for a key frame.
        guard bits.read(1) == 0, bits.read(1) == 0 else { return nil }
        _ = bits.read(2)
        guard bits.read(24) == 0x49_8342 else { return nil }
        bitDepth = profile >= 2 ? (bits.read(1) == 1 ? 12 : 10) : 8
        colorSpace = bits.read(3)
        if colorSpace != 7 {
            isFullRange = bits.read(1) == 1
            if profile == 1 || profile == 3 {
                subsamplingX = bits.read(1) == 1
                subsamplingY = bits.read(1) == 1
            } else {
                subsamplingX = true
                subsamplingY = true
            }
        } else {
            isFullRange = true
            subsamplingX = false
            subsamplingY = false
        }
        guard !bits.isExhausted else { return nil }
    }

    /// The `vpcC` payload (VP Codec ISO Media File Format Binding §2.3, version 1): the profile, a
    /// level from the picture's size, the bit depth, chroma and range, and the colour description the
    /// header's `color_space` implies.
    public func configurationRecord(width: Int, height: Int) -> Data {
        let chroma: UInt8 = switch (subsamplingX, subsamplingY) {
        case (true, true): 0
        case (true, false): 2
        default: 3
        }
        // Colour primaries, transfer characteristics and matrix coefficients (ISO/IEC 23091-2).
        let colour: [UInt8] = switch colorSpace {
        case 1, 3: [6, 6, 6]
        case 2: [1, 1, 1]
        case 4: [7, 7, 7]
        case 5: [9, bitDepth == 12 ? 15 : 14, 9]
        case 7: [2, 2, 0]
        default: [2, 2, 2]
        }
        return Data([
            1, 0, 0, 0,
            UInt8(profile),
            Self.level(width: width, height: height),
            UInt8(bitDepth) << 4 | chroma << 1 | (isFullRange ? 1 : 0),
            colour[0], colour[1], colour[2],
            0, 0
        ])
    }

    /// The lowest VP9 level whose largest picture holds `width` × `height` (VP9 levels table), written
    /// as ten times the level.
    static func level(width: Int, height: Int) -> UInt8 {
        let size = width * height
        let levels: [(Int, UInt8)] = [
            (36864, 10), (73728, 11), (122_880, 20), (245_760, 21), (552_960, 30),
            (983_040, 31), (2_228_224, 40), (8_912_896, 50)
        ]
        return levels.first { size <= $0.0 }?.1 ?? 60
    }
}

/// Reads bits most significant first, as VP9's headers are written.
struct ForwardBitReader {
    let bytes: [UInt8]
    var position = 0
    /// Set once a read asked for more bits than there are.
    private(set) var isExhausted = false

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func read(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            guard position < bytes.count * 8 else {
                isExhausted = true
                return value
            }
            value = value << 1 | Int(bytes[position / 8] >> (7 - position % 8) & 1)
            position += 1
        }
        return value
    }
}
