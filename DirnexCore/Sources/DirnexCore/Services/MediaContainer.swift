import Foundation

/// The container a movie or a sound is kept in, for Quick View's card in place of a file nothing here
/// can play (PLAN.md §M42 ▸ Slice 2).
///
/// **Read from the file's first bytes, and named by its extension only when they say nothing.**
/// AVFoundation tells nothing at all about a file it refuses: measured 2026-11-19 over a sample of each
/// container, every refused one failed `load(.tracks)` with the same "Cannot Open" as its duration. And
/// the type macOS gives the file is not dependable either: `org.matroska.mkv` was declared on that Mac by
/// VLC alone, so without it a `.mkv` is a dynamic type that names nothing. The bytes are the one witness
/// every Mac has.
///
/// The names are the formats' own and are not translated, as a codec's are not.
public enum MediaContainer: String, Sendable, CaseIterable {
    case matroska
    case webM
    case avi
    /// Advanced Systems Format, which a `.wmv` and a `.wma` are too.
    case asf
    case ogg
    case realMedia
    case mxf
    case flashVideo
    case mpeg4
    case quickTime

    /// How the card names it.
    public var displayName: String {
        switch self {
        case .matroska: "Matroska"
        case .webM: "WebM"
        case .avi: "AVI"
        case .asf: "Windows Media"
        case .ogg: "Ogg"
        case .realMedia: "RealMedia"
        case .mxf: "MXF"
        case .flashVideo: "Flash Video"
        case .mpeg4: "MPEG-4"
        case .quickTime: "QuickTime"
        }
    }

    /// The container a file named with `fileExtension` is usually kept in, for the extensions macOS may
    /// leave without a type of its own. Only the containers AVFoundation refuses are listed: a name it
    /// does play is typed by macOS on every Mac, and its card, if it ever needs one, names it from the
    /// bytes.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "mkv", "mka", "mk3d": self = .matroska
        case "webm", "weba": self = .webM
        case "avi": self = .avi
        case "asf", "wmv", "wma": self = .asf
        // Not `.spx`, Speex in Ogg as well: macOS types it as a System Profiler report.
        case "ogg", "ogv", "oga", "ogm", "opus": self = .ogg
        case "rm", "rmvb": self = .realMedia
        case "mxf": self = .mxf
        case "flv": self = .flashVideo
        default: return nil
        }
    }

    /// How many leading bytes `sniff` wants. A Matroska file names its doc type in its first 40 or so,
    /// and an MXF file may put a run-in of up to 64 KiB before its first partition, which this does
    /// not cover: the sniff reads what the card can afford on every cursor step.
    public static let sniffLength = 4096

    /// The container `prefix`, a file's first bytes, opens with, or `nil` when it opens with none of
    /// these.
    public static func sniff(_ prefix: Data) -> MediaContainer? {
        let bytes = [UInt8](prefix.prefix(sniffLength))
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return ebmlDocType(bytes) }
        if bytes.starts(with: Array("RIFF".utf8)), bytes.count >= 12,
           Array(bytes[8..<12]) == Array("AVI ".utf8) {
            return .avi
        }
        if bytes.starts(with: asfHeaderGUID) { return .asf }
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        if bytes.starts(with: Array(".RMF".utf8)) { return .realMedia }
        if bytes.starts(with: mxfPartitionKey) { return .mxf }
        if bytes.starts(with: Array("FLV".utf8) + [0x01]) { return .flashVideo }
        return isoBaseMedia(bytes)
    }

    /// The ASF Header Object's GUID, as it is laid out on disk: the first three fields little-endian.
    private static let asfHeaderGUID: [UInt8] = [
        0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
        0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C
    ]

    /// The first eleven bytes of an MXF partition pack's key, which SMPTE 377 fixes for every kind of
    /// partition. What follows says which kind, and the sample's says a closed, complete header.
    private static let mxfPartitionKey: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02
    ]

    /// An ISO base media file — MPEG-4 and its family — or a QuickTime movie, told apart by the brand
    /// its `ftyp` box names. An old QuickTime movie has no `ftyp` and opens with one of its own atoms.
    private static func isoBaseMedia(_ bytes: [UInt8]) -> MediaContainer? {
        guard bytes.count >= 8 else { return nil }
        let box = Array(bytes[4..<8])
        if box == Array("ftyp".utf8) {
            guard bytes.count >= 12 else { return .mpeg4 }
            return Array(bytes[8..<12]) == Array("qt  ".utf8) ? .quickTime : .mpeg4
        }
        let quickTimeAtoms = ["moov", "mdat", "wide", "free", "skip", "pnot"].map { Array($0.utf8) }
        return quickTimeAtoms.contains(box) ? .quickTime : nil
    }

    // MARK: - EBML

    /// Matroska or WebM, by the `DocType` in an EBML header (RFC 8794), or `nil` for an EBML document
    /// of some other kind, or a header cut off before it says.
    ///
    /// The header's elements are read flat, since none of them is a master: `DocType` is `0x4282`, and
    /// both a one-byte size and the eight-byte one some muxers write for every element are read.
    private static func ebmlDocType(_ bytes: [UInt8]) -> MediaContainer? {
        var cursor = 4
        guard let headerSize = readVariableInteger(bytes, at: &cursor, keepingMarker: false) else {
            return nil
        }
        let end = min(bytes.count, cursor + Int(clamping: headerSize))
        while cursor < end {
            guard let id = readVariableInteger(bytes, at: &cursor, keepingMarker: true),
                  let size = readVariableInteger(bytes, at: &cursor, keepingMarker: false),
                  size <= UInt64(end - cursor)
            else { return nil }
            let body = bytes[cursor..<cursor + Int(size)]
            cursor += Int(size)
            guard id == 0x4282 else { continue }
            // A string element may be padded with NULs to its size.
            let name = String(bytes: body.prefix { $0 != 0 }, encoding: .utf8)
            return switch name {
            case "matroska": .matroska
            case "webm": .webM
            default: nil
            }
        }
        return nil
    }

    /// An EBML variable-length integer at `cursor`, moving past it. An element ID keeps its length
    /// marker, which is how IDs are written down (`0x4282`); a size drops it. A size of all ones means
    /// "unknown", which the header never uses, and is answered as `nil` with every malformed case.
    private static func readVariableInteger(
        _ bytes: [UInt8],
        at cursor: inout Int,
        keepingMarker: Bool
    ) -> UInt64? {
        guard cursor < bytes.count, bytes[cursor] != 0 else { return nil }
        let first = bytes[cursor]
        let length = first.leadingZeroBitCount + 1
        guard cursor + length <= bytes.count else { return nil }
        let marker = UInt8(0x80) >> (length - 1)
        let valueBits = marker &- 1
        var value = UInt64(keepingMarker ? first : first & valueBits)
        var allOnes = first & valueBits == valueBits
        for byte in bytes[cursor + 1..<cursor + length] {
            value = value << 8 | UInt64(byte)
            allOnes = allOnes && byte == 0xFF
        }
        cursor += length
        if !keepingMarker, allOnes { return nil }
        return value
    }
}
