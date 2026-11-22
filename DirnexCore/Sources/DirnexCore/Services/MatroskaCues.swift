import Foundation

/// One entry of a Matroska file's index (`CuePoint`): a time, and where the clusters holding each
/// track's block for that time start (PLAN.md §M42 ▸ Slice 3).
///
/// A muxer cues the video's keyframes, so a seek goes to the cue at or before its target and decodes
/// forward from the cluster it names. mkvmerge cued the film once every 5 seconds or so, 1 126 cues
/// over 95 minutes; libwebm cued each cluster.
public struct MatroskaCuePoint: Equatable, Sendable {
    public struct Position: Equatable, Sendable {
        public let track: UInt64
        /// Where the cluster starts, in the file: the segment-relative position the file records,
        /// already added to where the segment's data starts.
        public let clusterOffset: UInt64
        /// Where the block starts inside the cluster's data, when the muxer wrote it.
        public let relativePosition: UInt64?
        /// Which block of the cluster it is, counting from 1, when the muxer wrote it.
        public let blockNumber: UInt64?
    }

    /// The time, in ticks.
    public let time: UInt64
    public let positions: [Position]
}

extension MatroskaFile {
    /// The most of a `Cues` element this reader holds in memory. The film's is 20 KiB, and a cue costs
    /// about 18 bytes, so this is room for some three million.
    static let cuesLimit = 64 * 1024 * 1024

    /// The file's cues in time order, read from wherever its `Cues` element is; none for a file with
    /// none, as a live recording has.
    ///
    /// Cues are found before the first cluster or through a `SeekHead`, which every muxer seen names
    /// them in. Cues after the clusters that no `SeekHead` names are not looked for: finding them would
    /// mean stepping over every cluster first, 6 902 reads across the film.
    public func cues() throws -> [MatroskaCuePoint] {
        guard let cuesOffset else { return [] }
        var reader = EBMLReader(source: source)
        guard let element = try reader.element(at: cuesOffset), element.id == MatroskaHead.cues else {
            throw MatroskaError.malformed(offset: cuesOffset)
        }
        guard let size = element.size else { throw MatroskaError.malformed(offset: cuesOffset) }
        guard size <= UInt64(Self.cuesLimit) else { throw MatroskaError.tooLarge(offset: cuesOffset) }
        guard element.dataOffset + size <= source.length else { throw MatroskaError.truncated }
        var points: [MatroskaCuePoint] = []
        for point in try reader.children(of: element) where point.id == 0xBB {
            if let cue = try readCuePoint(point, with: &reader) { points.append(cue) }
        }
        // Sorted by the muxer in every file seen, and kept stable for the one that is not.
        return points.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Where to start reading for `ticks` on `track`: the last of `cues` at or before it that names the
    /// track, or `nil` when none does, which means the first cluster.
    public static func cue(
        atOrBefore ticks: Int64,
        track: UInt64,
        in cues: [MatroskaCuePoint]
    ) -> (time: UInt64, position: MatroskaCuePoint.Position)? {
        guard ticks >= 0 else { return nil }
        let target = UInt64(ticks)
        // The first cue after the target, by halving.
        var low = 0
        var high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].time <= target { low = middle + 1 } else { high = middle }
        }
        for cue in cues[..<low].reversed() {
            if let position = cue.positions.first(where: { $0.track == track }) {
                return (cue.time, position)
            }
        }
        return nil
    }

    private func readCuePoint(_ point: EBMLElement, with reader: inout EBMLReader) throws -> MatroskaCuePoint? {
        var time: UInt64?
        var positions: [MatroskaCuePoint.Position] = []
        for child in try reader.children(of: point) {
            switch child.id {
            case 0xB3: time = try reader.unsigned(child) ?? 0
            case 0xB7: if let position = try readPosition(child, with: &reader) { positions.append(
                    position
                ) }
            default: break
            }
        }
        guard let time, !positions.isEmpty else { return nil }
        return MatroskaCuePoint(time: time, positions: positions)
    }

    private func readPosition(
        _ element: EBMLElement,
        with reader: inout EBMLReader
    ) throws -> MatroskaCuePoint.Position? {
        var track: UInt64?
        var cluster: UInt64?
        var relative: UInt64?
        var number: UInt64?
        for child in try reader.children(of: element) {
            switch child.id {
            case 0xF7: track = try reader.unsigned(child)
            case 0xF1: cluster = try reader.unsigned(child) ?? 0
            case 0xF0: relative = try reader.unsigned(child)
            case 0x5378: number = try reader.unsigned(child)
            default: break
            }
        }
        guard let track, let cluster else { return nil }
        let (offset, overflow) = segmentDataOffset.addingReportingOverflow(cluster)
        guard !overflow else { return nil }
        return MatroskaCuePoint.Position(
            track: track,
            clusterOffset: offset,
            relativePosition: relative,
            blockNumber: number
        )
    }
}
