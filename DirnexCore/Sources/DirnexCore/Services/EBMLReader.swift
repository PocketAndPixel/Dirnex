import Foundation

/// One EBML element's header (RFC 8794): its ID, where it starts, and where its data lies.
struct EBMLElement: Equatable {
    /// The ID with its length marker kept, which is how IDs are written down (`0x1A45DFA3`).
    let id: UInt32
    /// Where the element's ID starts.
    let offset: UInt64
    /// Where its data starts.
    let dataOffset: UInt64
    /// Its data's length, or `nil` when the writer did not know it: a live stream's segment and
    /// clusters are written before their ends are, and RFC 8794 spells that "unknown" as all ones.
    let size: UInt64?

    /// Where the element ends, when its size is known.
    var end: UInt64? {
        size.map { dataOffset + $0 }
    }
}

/// An EBML variable-length integer as read: its value, how many bytes it took, and whether it is the
/// all-ones size that means "unknown".
struct EBMLVariableInteger {
    let value: UInt64
    let length: Int
    let isUnknown: Bool
}

/// Reads EBML elements and their values out of a `RandomAccessByteSource`, through a window of the
/// file it keeps between calls (PLAN.md §M42 ▸ Slice 3).
///
/// The window is what makes reading element by element affordable: a cluster's block headers sit a few
/// kilobytes apart at most in an audio run, so one read serves dozens of them, and a jump over a video
/// frame costs one more read rather than the frame's bytes.
struct EBMLReader {
    let source: any RandomAccessByteSource
    /// How much a read past the window fetches, at the least.
    let windowSize: Int
    private var window: [UInt8] = []
    private var windowStart: UInt64 = 0

    init(source: any RandomAccessByteSource, windowSize: Int = 16 * 1024) {
        self.source = source
        self.windowSize = windowSize
    }

    var length: UInt64 { source.length }

    // MARK: - Bytes

    /// Up to `count` bytes from `offset`, fewer where the file ends.
    mutating func bytes(at offset: UInt64, count: Int) throws -> ArraySlice<UInt8> {
        guard count > 0, offset < length else { return [] }
        let windowEnd = windowStart + UInt64(window.count)
        let wanted = min(UInt64(count), length - offset)
        if offset < windowStart || offset + wanted > windowEnd {
            window = try [UInt8](source.read(at: offset, count: max(count, windowSize)))
            windowStart = offset
        }
        let start = Int(offset - windowStart)
        return window[start..<min(window.count, start + count)]
    }

    /// The byte at `offset`, or `nil` past the end of the file.
    mutating func byte(at offset: UInt64) throws -> UInt8? {
        try bytes(at: offset, count: 1).first
    }

    // MARK: - Headers

    /// The element whose header starts at `offset`, or `nil` when the file ends there.
    ///
    /// Throws `malformed` for a header that cannot be one, a zero byte where a length marker belongs
    /// or an ID longer than four bytes, and `truncated` for one the end of the file cuts in two.
    mutating func element(at offset: UInt64) throws -> EBMLElement? {
        guard offset < length else { return nil }
        let head = try bytes(at: offset, count: 12)
        guard let id = Self.variableInteger(head, keepingMarker: true), id.length <= 4,
              let size = Self.variableInteger(head.dropFirst(id.length), keepingMarker: false)
        else {
            throw Self.isCut(head) ? MatroskaError.truncated : MatroskaError.malformed(
                offset: offset
            )
        }
        let dataOffset = offset + UInt64(id.length + size.length)
        return EBMLElement(
            id: UInt32(id.value),
            offset: offset,
            dataOffset: dataOffset,
            size: size.isUnknown ? nil : size.value
        )
    }

    /// Whether a header failed to read only because `head`, what was left of the file, ends inside it.
    private static func isCut(_ head: ArraySlice<UInt8>) -> Bool {
        guard let first = head.first, first != 0 else { return false }
        let idLength = first.leadingZeroBitCount + 1
        guard head.count > idLength else { return true }
        let sizeFirst = head[head.startIndex + idLength]
        guard sizeFirst != 0 else { return false }
        return head.count < idLength + sizeFirst.leadingZeroBitCount + 1
    }

    /// An EBML variable-length integer at the start of `bytes`: its value and how many bytes it took.
    /// An element ID keeps its length marker; a size drops it, and a size whose value bits are all ones
    /// is "unknown".
    static func variableInteger(_ bytes: ArraySlice<UInt8>, keepingMarker: Bool) -> EBMLVariableInteger? {
        guard let first = bytes.first, first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard bytes.count >= length else { return nil }
        let valueBits = (UInt8(0x80) >> (length - 1)) &- 1
        var value = UInt64(keepingMarker ? first : first & valueBits)
        var allOnes = first & valueBits == valueBits
        for byte in bytes.dropFirst().prefix(length - 1) {
            value = value << 8 | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        return EBMLVariableInteger(
            value: value,
            length: length,
            isUnknown: !keepingMarker && allOnes
        )
    }

    // MARK: - Values

    /// The element's data, which must lie wholly inside the file and be no longer than `limit`.
    mutating func data(of element: EBMLElement, limit: Int) throws -> ArraySlice<UInt8> {
        guard let size = element.size else { throw MatroskaError.malformed(offset: element.offset) }
        guard size <= UInt64(limit) else { throw MatroskaError.tooLarge(offset: element.offset) }
        let bytes = try bytes(at: element.dataOffset, count: Int(size))
        guard bytes.count == Int(size) else { throw MatroskaError.truncated }
        return bytes
    }

    /// An unsigned integer of up to eight bytes, or `nil` for an empty one, which RFC 8794 reads as the
    /// element's default.
    mutating func unsigned(_ element: EBMLElement) throws -> UInt64? {
        let bytes = try data(of: element, limit: 8)
        guard !bytes.isEmpty else { return nil }
        return bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// A two's-complement signed integer of up to eight bytes, or `nil` for an empty one.
    mutating func signed(_ element: EBMLElement) throws -> Int64? {
        let bytes = try data(of: element, limit: 8)
        guard let first = bytes.first else { return nil }
        let unsigned = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let bits = UInt64(bytes.count * 8)
        // Sign-extend from the element's own width.
        if first & 0x80 != 0, bits < 64 {
            return Int64(bitPattern: unsigned | ~((UInt64(1) << bits) - 1))
        }
        return Int64(bitPattern: unsigned)
    }

    /// A four- or eight-byte IEEE float, or `nil` for an empty one.
    mutating func float(_ element: EBMLElement) throws -> Double? {
        let bytes = try data(of: element, limit: 8)
        let bits = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch bytes.count {
        case 0: return nil
        case 4: return Double(Float(bitPattern: UInt32(bits)))
        case 8: return Double(bitPattern: bits)
        default: throw MatroskaError.malformed(offset: element.offset)
        }
    }

    /// A string, with the NULs RFC 8794 allows after it removed, or `nil` for an empty one. Bytes that
    /// are not UTF-8 are repaired rather than refused, since a title is worth reading even when a muxer
    /// wrote it in a code page.
    mutating func string(_ element: EBMLElement) throws -> String? {
        let bytes = try data(of: element, limit: 64 * 1024).prefix { $0 != 0 }
        return bytes.isEmpty ? nil : SubprocessText.lossyUTF8(Data(bytes))
    }

    /// Binary data of up to `limit` bytes.
    mutating func binary(_ element: EBMLElement, limit: Int) throws -> Data {
        try Data(data(of: element, limit: limit))
    }

    // MARK: - Children

    /// The children of `parent`, in order. `parent` must have a known size: an element whose size is
    /// unknown ends where something that cannot be its child begins, which only the caller knows.
    ///
    /// `preloading` reads the whole parent in one go, which is right for a parent whose children are
    /// all about to be read (`Tracks`, `Cues`) and wrong for one holding a frame (`BlockGroup`).
    mutating func children(of parent: EBMLElement, preloading: Bool = true) throws -> [EBMLElement] {
        guard let end = parent.end else { throw MatroskaError.malformed(offset: parent.offset) }
        if preloading {
            _ = try bytes(at: parent.dataOffset, count: Int(clamping: end - parent.dataOffset))
        }
        var children: [EBMLElement] = []
        var offset = parent.dataOffset
        while offset < end {
            guard let child = try element(at: offset) else { throw MatroskaError.truncated }
            guard let childEnd = child.end, childEnd <= end else {
                throw MatroskaError.malformed(offset: child.offset)
            }
            children.append(child)
            offset = childEnd
        }
        return children
    }
}
