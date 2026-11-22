import Foundation

/// MPEG-4 Part 2 video (ISO/IEC 14496-2) as an AVI keeps it (PLAN.md §M42 ▸ Slice 5): what DivX and
/// Xvid wrote, and the codec of most AVIs from the years AVI was the way films were passed around.
///
/// Core Media decodes it as `mp4v`, configured by the headers before the first picture (the visual
/// object sequence, the visual object and the video object layer), which an MP4 carries in its `esds`
/// and an AVI in its first frame. The 3GP sample on this Mac is Xvid in an MP4 box, and its `esds`
/// holds exactly those headers, Xvid's own user data among them.
enum MPEG4Visual {
    /// A video object plane's coding type: what this reader calls a frame.
    enum PlaneType: Int, Sendable {
        case intra = 0
        case predicted = 1
        case bidirectional = 2
        case sprite = 3

        /// Whether later frames are made from it, so it is shown only after the B-frames that come
        /// after it in the file.
        var isAnchor: Bool { self != .bidirectional }
    }

    /// One plane's header: its type, and whether anything is coded in it. DivX writes a plane with
    /// nothing coded as a placeholder for the tick its packed B-frames took (`split(_:)`).
    struct PlaneHeader: Equatable, Sendable {
        let type: PlaneType
        let isCoded: Bool
    }

    static let planeStartCode: UInt8 = 0xB6
    static let groupStartCode: UInt8 = 0xB3

    /// The headers before `frame`'s first group of planes or plane, when they include a video object
    /// layer (start codes 0x20 to 0x2F): the decoder's configuration.
    static func configuration(_ frame: Data) -> Data? {
        let bytes = [UInt8](frame.prefix(4096))
        var hasLayer = false
        for start in startCodes(bytes) {
            let code = bytes[start + 3]
            if code == planeStartCode || code == groupStartCode {
                return hasLayer && start > 0 ? Data(bytes[..<start]) : nil
            }
            if (0x20...0x2F).contains(code) { hasLayer = true }
        }
        return nil
    }

    /// How many bits each plane's `vop_time_increment` takes: enough for the layer's
    /// `vop_time_increment_resolution` less one, and at least one (§6.3.3). The header is read as far as
    /// that field, and a plane cannot be read without it.
    static func timeIncrementBits(configuration: Data) -> Int? {
        let bytes = [UInt8](configuration)
        guard let start = startCodes(bytes).first(where: { (0x20...0x2F).contains(bytes[$0 + 3]) })
        else { return nil }
        var bits = ForwardBitReader(Array(bytes[(start + 4)...]))
        _ = bits.read(1)
        _ = bits.read(8)
        var version = 1
        if bits.read(1) == 1 {
            version = bits.read(4)
            _ = bits.read(3)
        }
        if bits.read(4) == 15 { _ = bits.read(16) }
        if bits.read(1) == 1 {
            _ = bits.read(3)
            if bits.read(1) == 1 { _ = bits.read(79) }
        }
        let shape = bits.read(2)
        if shape == 3, version != 1 { _ = bits.read(4) }
        _ = bits.read(1)
        let resolution = bits.read(16)
        guard !bits.isExhausted, resolution > 0 else { return nil }
        var count = 1
        while 1 << count < resolution {
            count += 1
        }
        return count
    }

    /// The plane starting at `plane`'s first plane start code, given the layer's time increment width.
    static func planeHeader(_ plane: Data, timeIncrementBits: Int) -> PlaneHeader? {
        let bytes = [UInt8](plane.prefix(64))
        guard let start = startCodes(bytes).first(where: { bytes[$0 + 3] == planeStartCode }),
              let type = PlaneType(
                  rawValue: Int(bytes.count > start + 4 ? bytes[start + 4] >> 6 : 0)
              )
        else { return nil }
        var bits = ForwardBitReader(Array(bytes[(start + 4)...]))
        _ = bits.read(2)
        var seconds = 0
        while bits.read(1) == 1, !bits.isExhausted, seconds < 64 {
            seconds += 1
        }
        _ = bits.read(1)
        _ = bits.read(timeIncrementBits)
        _ = bits.read(1)
        let coded = bits.read(1) == 1
        guard !bits.isExhausted else { return nil }
        return PlaneHeader(type: type, isCoded: coded)
    }

    /// The planes in one AVI chunk. Usually one; DivX's *packed bitstream* puts a P-frame and the
    /// B-frame shown before it in one chunk, so that each chunk keeps one tick, and leaves the next
    /// chunk a plane with nothing coded. The headers before the first plane stay with it.
    static func split(_ frame: Data) -> [Data] {
        let bytes = [UInt8](frame)
        let planes = startCodes(bytes).filter { bytes[$0 + 3] == planeStartCode }
        guard planes.count > 1 else { return [frame] }
        let bounds = [0] + planes.dropFirst() + [bytes.count]
        return zip(bounds, bounds.dropFirst()).map { Data(bytes[$0..<$1]) }
    }

    /// The sample description's `esds` atom for `configuration`: an `esds` box's version and flags,
    /// then an `ES_Descriptor` naming MPEG-4 visual (object type 0x20, a visual stream) around the
    /// headers, as the 3GP sample's own atom is laid out.
    static func esds(configuration: Data) -> Data {
        Data([0, 0, 0, 0]) + ElementaryStreamDescriptor.make(
            objectType: 0x20,
            streamType: 0x11,
            specificInfo: configuration
        )
    }

    /// Where each start code (`00 00 01`, then a code byte) begins.
    static func startCodes(_ bytes: [UInt8]) -> [Int] {
        var starts: [Int] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append(index)
                index += 3
            } else {
                index += 1
            }
        }
        return starts
    }
}

/// An MPEG-4 Systems `ES_Descriptor` (ISO/IEC 14496-1 §7.2.6.5), the configuration MP4 boxes and
/// Core Media's magic cookies carry for AAC and MPEG-4 video alike.
enum ElementaryStreamDescriptor {
    /// A descriptor holding a `DecoderConfigDescriptor` of `objectType` and `streamType` (its upper
    /// six bits the stream type, the reserved bit set) around `specificInfo`, then an
    /// `SLConfigDescriptor`, each size in four bytes. The buffer size and bit rates are left zero,
    /// which no decoder reads.
    static func make(objectType: UInt8, streamType: UInt8, specificInfo: Data) -> Data {
        var decoderConfig = Data([objectType, streamType, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        decoderConfig.append(descriptor(0x05, specificInfo))
        var elementary = Data([0, 0, 0])
        elementary.append(descriptor(0x04, decoderConfig))
        elementary.append(descriptor(0x06, Data([0x02])))
        return descriptor(0x03, elementary)
    }

    private static func descriptor(_ tag: UInt8, _ body: Data) -> Data {
        let size = body.count
        var data = Data([
            tag,
            0x80 | UInt8(truncatingIfNeeded: size >> 21),
            0x80 | UInt8(truncatingIfNeeded: size >> 14),
            0x80 | UInt8(truncatingIfNeeded: size >> 7),
            UInt8(truncatingIfNeeded: size) & 0x7F
        ])
        data.append(body)
        return data
    }
}
