import Foundation

/// Why a Matroska or WebM file could not be read.
public enum MatroskaError: Error, Equatable, Sendable {
    /// No EBML header, or one naming a kind of document that is neither Matroska nor WebM.
    case notMatroska
    /// The bytes at `offset` break the format: a length marker of zero, an element running past its
    /// parent, lace sizes adding up to more than their block.
    case malformed(offset: UInt64)
    /// An element at `offset` larger than this reader holds in memory.
    case tooLarge(offset: UInt64)
    /// The file ends before something it promised: its tracks, or an element its header began.
    case truncated
    /// Frames of a track whose encoding this reader does not undo (`MatroskaFrameEncoding`).
    case unreadableFrames(track: UInt64)
}

/// The segment's `Info`: its clock and its length.
public struct MatroskaInfo: Equatable, Sendable {
    /// Nanoseconds per tick of every timestamp in the file. One million, so ticks are milliseconds, in
    /// every file met so far, and the specification's default.
    public var timestampScale: UInt64 = 1_000_000
    /// The length in ticks, which Matroska writes as a float.
    public var duration: Double?
    public var title: String?
    public var muxingApp: String?
    public var writingApp: String?

    public init() {}

    /// The length in seconds.
    public var durationSeconds: Double? {
        duration.map { $0 * Double(timestampScale) / 1_000_000_000 }
    }
}

/// A Matroska or WebM file, read as far as its tracks (PLAN.md §M42 ▸ Slice 3), with its cues and its
/// clusters read when asked for.
///
/// **Opening reads only the head.** A film keeps its cues at the end of 10 GB, and Quick View's card
/// wants the tracks alone, on a cursor step; so `init` reads the EBML header, the level-one elements up
/// to the first cluster, and whatever the `SeekHead` says lies elsewhere of `Info` and `Tracks`, and
/// notes where the cues are. `cues()` and `cluster(from:)` read the rest.
///
/// Seen 2026-11-20 across mkvmerge from 3.4 (2010) to 88, libwebm, FFmpeg's Lavf and NCH Prism: every
/// one puts `Info` and `Tracks` before the first cluster and the cues after the last, behind a
/// `SeekHead` at the start, and writes an eight-byte size as readily as a one-byte one.
public struct MatroskaFile: Sendable {
    public let container: MediaContainer
    public let info: MatroskaInfo
    public let tracks: [MatroskaTrack]
    /// Where the first cluster starts, or `nil` for a file with none.
    public let firstClusterOffset: UInt64?
    /// Where the `Cues` element starts, when the file has one.
    public let cuesOffset: UInt64?

    let source: any RandomAccessByteSource
    /// Where the segment's data starts, which every position the file records is counted from.
    let segmentDataOffset: UInt64
    /// Where the segment ends: its size, or the end of the file when that is unknown or cut short.
    let segmentEnd: UInt64

    /// The most this reader holds in memory of one element of the head (`Info`, `Tracks`, a
    /// `SeekHead`, a codec's private data). A film's `Tracks` with thirteen tracks is 1.3 KiB.
    static let headElementLimit = 16 * 1024 * 1024

    public init(source: any RandomAccessByteSource) throws {
        var reader = EBMLReader(source: source)
        container = try Self.readHeader(with: &reader)
        let segment = try Self.findSegment(with: &reader)
        self.source = source
        segmentDataOffset = segment.dataOffset
        segmentEnd = min(segment.end ?? source.length, source.length)
        var head = try MatroskaHead.read(
            from: segment.dataOffset,
            to: segmentEnd,
            segmentDataOffset: segment.dataOffset,
            with: &reader
        )
        try head.followSeekHead(segmentEnd: segmentEnd, with: &reader)
        guard let tracks = head.tracks else {
            let isCut = head.sawEnd || (segment.end ?? 0) > source.length
            throw isCut ? MatroskaError.truncated : MatroskaError.malformed(offset: segment.offset)
        }
        info = head.info ?? MatroskaInfo()
        self.tracks = tracks
        firstClusterOffset = head.firstClusterOffset
        cuesOffset = head.cuesOffset
    }

    /// The track blocks name `number` by.
    public func track(number: UInt64) -> MatroskaTrack? {
        tracks.first { $0.number == number }
    }

    /// `ticks` of the file's clock in nanoseconds, held at the ends of `Int64` rather than wrapping.
    public func nanoseconds(ticks: Int64) -> Int64 {
        let (product, overflow) = ticks.multipliedReportingOverflow(
            by: Int64(clamping: info.timestampScale)
        )
        guard overflow else { return product }
        return ticks < 0 ? .min : .max
    }

    // MARK: - The EBML header and the segment

    /// Matroska or WebM, by the EBML header's `DocType`.
    private static func readHeader(with reader: inout EBMLReader) throws -> MediaContainer {
        guard let header = try? reader.element(at: 0), header.id == 0x1A45DFA3, header.size != nil,
              let docType = try reader.children(of: header).first(where: { $0.id == 0x4282 })
        else { throw MatroskaError.notMatroska }
        switch try reader.string(docType) {
        case "matroska": return .matroska
        case "webm": return .webM
        default: throw MatroskaError.notMatroska
        }
    }

    /// The `Segment` after the EBML header, past anything else at the top level with a size to skip by.
    private static func findSegment(with reader: inout EBMLReader) throws -> EBMLElement {
        var offset = try reader.element(at: 0)?.end ?? 0
        while let element = try reader.element(at: offset) {
            if element.id == 0x18538067 { return element }
            guard let end = element.end else { throw MatroskaError.malformed(offset: offset) }
            offset = end
        }
        throw MatroskaError.truncated
    }
}

/// The level-one elements of a segment's head, as `MatroskaFile.init` collects them.
struct MatroskaHead {
    var info: MatroskaInfo?
    var tracks: [MatroskaTrack]?
    var firstClusterOffset: UInt64?
    var cuesOffset: UInt64?
    /// Absolute offsets the `SeekHead`s name, by element ID, in the order they name them.
    var seekPositions: [UInt32: [UInt64]] = [:]
    /// Whether the walk ran into the end of the file before a cluster.
    var sawEnd = false
    let segmentDataOffset: UInt64

    static let seekHead: UInt32 = 0x114D9B74
    static let info: UInt32 = 0x1549A966
    static let tracks: UInt32 = 0x1654AE6B
    static let cues: UInt32 = 0x1C53BB6B
    static let cluster: UInt32 = 0x1F43B675

    /// Walks the segment's level-one elements from `start` to the first cluster.
    static func read(
        from start: UInt64,
        to end: UInt64,
        segmentDataOffset: UInt64,
        with reader: inout EBMLReader
    ) throws -> MatroskaHead {
        var head = MatroskaHead(segmentDataOffset: segmentDataOffset)
        var offset = start
        while offset < end {
            guard let element = try reader.element(at: offset) else { break }
            if element.id == cluster {
                head.firstClusterOffset = element.offset
                return head
            }
            guard let elementEnd = element.end else { throw MatroskaError.malformed(offset: offset) }
            // Where the cues start is worth keeping even when the file ends inside them, so that
            // `cues()` can say they were cut rather than that there are none.
            if element.id == cues, head.cuesOffset == nil { head.cuesOffset = element.offset }
            guard elementEnd <= reader.length else { break }
            try head.take(element, with: &reader)
            offset = elementEnd
        }
        // A segment that ends where its size says, with no cluster, has simply ended.
        head.sawEnd = offset < end
        return head
    }

    /// Reads `element` into the head if it is one the head keeps.
    mutating func take(_ element: EBMLElement, with reader: inout EBMLReader) throws {
        switch element.id {
        case Self.info where info == nil:
            info = try Self.readInfo(element, with: &reader)
        case Self.tracks where tracks == nil:
            tracks = try Self.readTracks(element, with: &reader)
        case Self.cues where cuesOffset == nil:
            cuesOffset = element.offset
        case Self.seekHead:
            try readSeekHead(element, with: &reader)
        default:
            break
        }
    }

    /// Whether something the head keeps is still neither read nor named by a `SeekHead`.
    private var isMissingSomething: Bool {
        info == nil || tracks == nil || (cuesOffset == nil && seekPositions[Self.cues] == nil)
    }

    /// Reads whatever the `SeekHead`s name that the walk did not reach: `Info` or `Tracks` placed after
    /// the clusters, the cues' position, and a second `SeekHead` naming any of them.
    ///
    /// A second `SeekHead` is read only while something is still missing. mkvmerge 3.4 put one at the
    /// end of the film naming all of its clusters (121 KiB), and the first had named everything the
    /// head needs already.
    mutating func followSeekHead(segmentEnd: UInt64, with reader: inout EBMLReader) throws {
        var visited: Set<UInt64> = []
        var pending = seekPositions[Self.seekHead] ?? []
        while isMissingSomething, let position = pending.popLast() {
            // A pointer to a `SeekHead` that is not one is passed over: the file may still say
            // everything the head needs elsewhere, and a damaged index is no reason to refuse it.
            guard visited.insert(position).inserted, position < segmentEnd,
                  let element = try? reader.element(at: position), element.id == Self.seekHead,
                  let end = element.end, end <= reader.length
            else { continue }
            let before = seekPositions[Self.seekHead]?.count ?? 0
            try? readSeekHead(element, with: &reader)
            pending += (seekPositions[Self.seekHead] ?? []).dropFirst(before)
        }
        if cuesOffset == nil { cuesOffset = seekPositions[Self.cues]?.first }
        for (id, missing) in [(Self.info, info == nil), (Self.tracks, tracks == nil)] where missing {
            guard let position = seekPositions[id]?.first, position < segmentEnd,
                  let element = try? reader.element(at: position), element.id == id,
                  let end = element.end, end <= reader.length
            else { continue }
            try take(element, with: &reader)
        }
    }

    private mutating func readSeekHead(_ element: EBMLElement, with reader: inout EBMLReader) throws {
        try Self.checkSize(element)
        for seek in try reader.children(of: element) where seek.id == 0x4DBB {
            var id: UInt32?
            var position: UInt64?
            for child in try reader.children(of: seek) {
                if child.id == 0x53AB {
                    let bytes = try reader.data(of: child, limit: 4)
                    id = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                }
                if child.id == 0x53AC { position = try reader.unsigned(child) }
            }
            guard let id, let position else { continue }
            let (absolute, overflow) = segmentDataOffset.addingReportingOverflow(position)
            if !overflow { seekPositions[id, default: []].append(absolute) }
        }
    }

    private static func readInfo(_ element: EBMLElement, with reader: inout EBMLReader) throws -> MatroskaInfo {
        try checkSize(element)
        var info = MatroskaInfo()
        for child in try reader.children(of: element) {
            switch child.id {
            case 0x2AD7B1:
                // A scale of zero would put every frame at the start.
                let scale = try reader.unsigned(child) ?? 0
                info.timestampScale = scale == 0 ? 1_000_000 : scale
            case 0x4489: info.duration = try reader.float(child)
            case 0x7BA9: info.title = try reader.string(child)
            case 0x4D80: info.muxingApp = try reader.string(child)
            case 0x5741: info.writingApp = try reader.string(child)
            default: break
            }
        }
        return info
    }

    private static func readTracks(_ element: EBMLElement, with reader: inout EBMLReader) throws -> [
        MatroskaTrack
    ] {
        try checkSize(element)
        var tracks: [MatroskaTrack] = []
        for entry in try reader.children(of: element) where entry.id == 0xAE {
            if let track = try MatroskaTrack.read(entry, with: &reader) { tracks.append(track) }
        }
        return tracks
    }

    private static func checkSize(_ element: EBMLElement) throws {
        guard let size = element.size else { throw MatroskaError.malformed(offset: element.offset) }
        guard size <= UInt64(MatroskaFile.headElementLimit) else {
            throw MatroskaError.tooLarge(offset: element.offset)
        }
    }
}
