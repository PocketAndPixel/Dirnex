import Foundation

/// One cluster of a Matroska or WebM file, read as an index of its blocks (PLAN.md §M42 ▸ Slice 3):
/// which track each belongs to, when it plays, and where each of its frames lies in the file. The
/// frames themselves stay on disk until `MatroskaFile.frame(_:of:)` reads one.
public struct MatroskaCluster: Equatable, Sendable {
    /// Where the cluster's element starts.
    public let offset: UInt64
    /// The cluster's time, in ticks, which its blocks' times are counted from.
    public let timestamp: UInt64
    public let blocks: [MatroskaBlock]
    /// Where the next level-one element starts, for the next `cluster(from:)`, or `nil` when the
    /// segment ends with this cluster or the file was cut inside it.
    public let nextOffset: UInt64?
    /// Whether the file ends inside this cluster, as a download stopped partway leaves it. Its blocks
    /// are the ones that were whole.
    public let isTruncated: Bool
}

/// One `SimpleBlock`, or the `Block` of a `BlockGroup` with what the group says of it.
public struct MatroskaBlock: Equatable, Sendable {
    /// The track's number (`MatroskaTrack.number`).
    public let track: UInt64
    /// When the block's first frame plays, in ticks of the file's clock. It can be negative: a
    /// block may start before its cluster's time, as audio's pre-roll does.
    public let timestamp: Int64
    /// How long the block lasts, in ticks, when a `BlockGroup` says (`BlockDuration`); subtitles do.
    public let duration: UInt64?
    /// A `SimpleBlock`'s own flag, or, for a `BlockGroup`, that it names no other block it depends on.
    public let isKeyframe: Bool
    public let isInvisible: Bool
    public let isDiscardable: Bool
    /// Nanoseconds of decoded sound to drop from the end (Opus at the end of a stream).
    public let discardPadding: Int64?
    /// Each frame's bytes in the file, as stored. A laced block holds several, which mkvmerge does
    /// for every audio track: eight AC-3 frames to a block in the films seen.
    public let frames: [Range<UInt64>]
}

extension MatroskaFile {
    /// The first cluster at or after `offset`, which is the start of an element at the segment's top
    /// level, read into an index of its blocks; or `nil` when the segment has no more clusters.
    /// Elements between clusters (`Void`, `Cues`, `Tags`) are stepped over.
    ///
    /// Start at `firstClusterOffset`, a cue's `clusterOffset`, or the last cluster's `nextOffset`.
    public func cluster(from offset: UInt64) throws -> MatroskaCluster? {
        var reader = EBMLReader(source: source, windowSize: Self.clusterWindow)
        var offset = offset
        while offset < segmentEnd {
            let element: EBMLElement?
            do {
                element = try reader.element(at: offset)
            } catch MatroskaError.truncated {
                return nil
            }
            guard let element else { return nil }
            if element.id == MatroskaHead.cluster {
                return try MatroskaClusterReader(segmentEnd: segmentEnd).read(element, with: &reader)
            }
            guard let end = element.end else { throw MatroskaError.malformed(offset: offset) }
            offset = end
        }
        return nil
    }

    /// Frame `index` of `block`, as the decoder wants it: with a header-stripped track's bytes put
    /// back in front.
    public func frame(_ index: Int, of block: MatroskaBlock) throws -> Data {
        let range = block.frames[index]
        let encoding = track(number: block.track)?.frameEncoding ?? .none
        guard encoding.isReadable else { throw MatroskaError.unreadableFrames(track: block.track) }
        let count = Int(clamping: range.upperBound - range.lowerBound)
        let stored = try source.read(at: range.lowerBound, count: count)
        guard stored.count == count else { throw MatroskaError.truncated }
        if case let .headerStripping(prefix) = encoding { return prefix + stored }
        return stored
    }

    /// When frame `index` of `block` plays, in nanoseconds: the block's time for its first frame, and
    /// for a later frame of a laced block that time plus the track's `DefaultDuration` for each frame
    /// before it. `nil` for a later frame of a track with no default duration, whose frames' lengths
    /// only its codec knows: mkvmerge 3.4 wrote none for the film's DTS tracks.
    public func frameTime(_ index: Int, of block: MatroskaBlock) -> Int64? {
        let start = nanoseconds(ticks: block.timestamp)
        guard index > 0 else { return start }
        guard let step = track(number: block.track)?.defaultDuration else { return nil }
        let (offset, overflow) = Int64(clamping: step).multipliedReportingOverflow(by: Int64(index))
        guard !overflow else { return nil }
        let (time, sumOverflow) = start.addingReportingOverflow(offset)
        return sumOverflow ? nil : time
    }

    /// How much of a cluster one read fetches. A film's clusters run about 1.5 MB, its audio blocks
    /// 12–16 KB apart and its video frames 76 KB on average, so a block's header is usually one read.
    static let clusterWindow = 64 * 1024
}

/// Reads one cluster's children into blocks.
struct MatroskaClusterReader {
    let segmentEnd: UInt64

    /// The level-one IDs, and the EBML header of a segment chained after this one: any of them ends a
    /// cluster whose size is unknown, which is how a live recording writes every cluster.
    private static let endsCluster: Set<UInt32> = [
        0x1F43B675, 0x1C53BB6B, 0x1254C367, 0x1043A770, 0x1941A469,
        0x114D9B74, 0x1549A966, 0x1654AE6B, 0x1A45DFA3, 0x18538067
    ]

    func read(_ cluster: EBMLElement, with reader: inout EBMLReader) throws -> MatroskaCluster {
        let limit = min(cluster.end ?? segmentEnd, segmentEnd)
        var timestamp: UInt64 = 0
        var blocks: [RelativeBlock] = []
        var offset = cluster.dataOffset
        var next = cluster.end
        var isTruncated = (cluster.end ?? 0) > reader.length
        while offset < limit {
            let child: EBMLElement
            do {
                guard let found = try reader.element(at: offset) else { break }
                child = found
            } catch MatroskaError.truncated {
                isTruncated = true
                break
            }
            if cluster.size == nil, Self.endsCluster.contains(child.id) {
                next = child.offset
                break
            }
            guard let childEnd = child.end else { throw MatroskaError.malformed(offset: child.offset) }
            guard childEnd <= limit else {
                if childEnd > reader.length {
                    isTruncated = true
                    break
                }
                throw MatroskaError.malformed(offset: child.offset)
            }
            switch child.id {
            case 0xE7: timestamp = try reader.unsigned(child) ?? 0
            case 0xA3: try blocks.append(Self.readBlock(child, isSimple: true, with: &reader))
            case 0xA0: try blocks.append(Self.readBlockGroup(child, with: &reader))
            default: break
            }
            offset = childEnd
        }
        if isTruncated || (cluster.size == nil && offset >= limit) { next = nil }
        let base = Int64(clamping: timestamp)
        return MatroskaCluster(
            offset: cluster.offset,
            timestamp: timestamp,
            blocks: blocks.map { $0.block(at: base) },
            nextOffset: next.flatMap { $0 < segmentEnd ? $0 : nil },
            isTruncated: isTruncated
        )
    }

    /// A block whose time is still relative to its cluster's, which the cluster may name after it.
    struct RelativeBlock {
        var track: UInt64
        var relativeTime: Int16
        var duration: UInt64?
        var isKeyframe: Bool
        var isInvisible: Bool
        var isDiscardable: Bool
        var discardPadding: Int64?
        var frames: [Range<UInt64>]

        func block(at clusterTime: Int64) -> MatroskaBlock {
            let (time, overflow) = clusterTime.addingReportingOverflow(Int64(relativeTime))
            return MatroskaBlock(
                track: track,
                timestamp: overflow ? clusterTime : time,
                duration: duration,
                isKeyframe: isKeyframe,
                isInvisible: isInvisible,
                isDiscardable: isDiscardable,
                discardPadding: discardPadding,
                frames: frames
            )
        }
    }

    private static func readBlockGroup(_ group: EBMLElement, with reader: inout EBMLReader) throws -> RelativeBlock {
        var blockElement: EBMLElement?
        var duration: UInt64?
        var hasReference = false
        var padding: Int64?
        for child in try reader.children(of: group, preloading: false) {
            switch child.id {
            case 0xA1: blockElement = child
            case 0x9B: duration = try reader.unsigned(child)
            case 0xFB: hasReference = true
            case 0x75A2: padding = try reader.signed(child)
            default: break
            }
        }
        guard let blockElement else { throw MatroskaError.malformed(offset: group.offset) }
        var block = try readBlock(blockElement, isSimple: false, with: &reader)
        block.duration = duration
        block.isKeyframe = !hasReference
        block.discardPadding = padding
        return block
    }

    /// A block's header and the frames its lacing divides it into.
    private static func readBlock(
        _ element: EBMLElement,
        isSimple: Bool,
        with reader: inout EBMLReader
    ) throws -> RelativeBlock {
        guard let end = element.end else { throw MatroskaError.malformed(offset: element.offset) }
        let head = try reader.bytes(
            at: element.dataOffset,
            count: Int(min(end - element.dataOffset, 12))
        )
        guard let track = EBMLReader.variableInteger(head, keepingMarker: false),
              head.count >= track.length + 3
        else { throw MatroskaError.malformed(offset: element.offset) }
        let timeIndex = head.startIndex + track.length
        let relativeTime = Int16(
            bitPattern: UInt16(head[timeIndex]) << 8 | UInt16(head[timeIndex + 1])
        )
        let flags = head[timeIndex + 2]
        let lacingStart = element.dataOffset + UInt64(track.length + 3)
        var lacing = MatroskaLacing(start: lacingStart, end: end, blockOffset: element.offset)
        let frames = try lacing.frames(kind: (flags >> 1) & 0b11, with: &reader)
        return RelativeBlock(
            track: track.value,
            relativeTime: relativeTime,
            duration: nil,
            isKeyframe: isSimple && flags & 0x80 != 0,
            isInvisible: flags & 0x08 != 0,
            isDiscardable: isSimple && flags & 0x01 != 0,
            discardPadding: nil,
            frames: frames
        )
    }
}

/// Divides a block's data into its frames, by the lacing its flags name (Matroska §10.4): none, Xiph's
/// runs of 255, EBML's signed differences, or equal sizes.
struct MatroskaLacing {
    /// Where the lacing header starts (just after the block's flags), and where the block ends.
    var position: UInt64
    let end: UInt64
    let blockOffset: UInt64

    init(start: UInt64, end: UInt64, blockOffset: UInt64) {
        position = start
        self.end = end
        self.blockOffset = blockOffset
    }

    mutating func frames(kind: UInt8, with reader: inout EBMLReader) throws -> [Range<UInt64>] {
        guard kind != 0 else { return [position..<end] }
        let count = Int(try nextByte(with: &reader)) + 1
        var sizes: [UInt64] = []
        switch kind {
        case 0b01:
            for _ in 0..<count - 1 { sizes.append(try xiphSize(with: &reader)) }
        case 0b11:
            sizes = try ebmlSizes(count: count, with: &reader)
        default:
            let total = end - position
            guard total % UInt64(count) == 0 else { throw malformed }
            sizes = Array(repeating: total / UInt64(count), count: count)
        }
        if kind != 0b10 {
            let stated = sizes.reduce(UInt64(0)) { $0.addingReportingOverflow($1).partialValue }
            guard stated <= end - position else { throw malformed }
            sizes.append(end - position - stated)
        }
        var frames: [Range<UInt64>] = []
        var start = position
        for size in sizes {
            guard size <= end - start else { throw malformed }
            frames.append(start..<start + size)
            start += size
        }
        return frames
    }

    private var malformed: MatroskaError { .malformed(offset: blockOffset) }

    private mutating func nextByte(with reader: inout EBMLReader) throws -> UInt8 {
        guard position < end, let byte = try reader.byte(at: position) else { throw malformed }
        position += 1
        return byte
    }

    /// A Xiph lace size: bytes of 255 added up until one that is not.
    private mutating func xiphSize(with reader: inout EBMLReader) throws -> UInt64 {
        var size: UInt64 = 0
        while true {
            let byte = try nextByte(with: &reader)
            size += UInt64(byte)
            if byte != 255 { return size }
        }
    }

    /// EBML lacing: the first size as an EBML integer, then each next one as a signed difference from
    /// the one before, biased by half its range.
    private mutating func ebmlSizes(count: Int, with reader: inout EBMLReader) throws -> [UInt64] {
        var sizes: [UInt64] = []
        guard count > 1 else { return sizes }
        var size = Int64(try nextInteger(with: &reader).value)
        sizes.append(UInt64(size))
        for _ in 0..<count - 2 {
            let (raw, length) = try nextInteger(with: &reader)
            let bias = (Int64(1) << (7 * length - 1)) - 1
            size += Int64(raw) - bias
            guard size >= 0 else { throw malformed }
            sizes.append(UInt64(size))
        }
        return sizes
    }

    private mutating func nextInteger(with reader: inout EBMLReader) throws -> (
        value: UInt64,
        length: Int
    ) {
        let bytes = try reader.bytes(at: position, count: Int(min(8, end - position)))
        guard let integer = EBMLReader.variableInteger(bytes, keepingMarker: false) else { throw malformed }
        position += UInt64(integer.length)
        return (integer.value, integer.length)
    }
}
