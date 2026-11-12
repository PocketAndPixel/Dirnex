import Foundation

/// Where two files differ at the same offset, as stretches a window can step through (PLAN.md §M37
/// Slice 1).
///
/// A stretch starts and ends on a differing byte, and every differing byte is inside one. Two
/// differing bytes share a stretch when fewer than ``gap`` equal bytes lie between them, so bytes on
/// one row of the view are one change rather than sixteen.
///
/// **The list is bounded, and what gives way is its resolution rather than its coverage.** Measured
/// 2026-11-08: sixteen bytes inserted near the start of a 1 GiB file make 4.2 million separate runs of
/// differing bytes, and alternating bytes could make 500 million. Past ``capacity`` the gap doubles
/// and the list is joined up again, as often as it takes to reach half of `capacity`. So no
/// difference is ever dropped, and only a pathological pair sees coarser stretches. The count of
/// differing bytes stays exact whatever happens to the stretches.
public struct BinaryDifferenceList: Sendable, Equatable {
    /// One run of the file in which the two sides differ.
    public struct Stretch: Sendable, Equatable {
        /// From the first differing byte to just past the last.
        public var range: Range<Int64>
        /// How many bytes in `range` differ. The rest are equal bytes the stretch was joined across.
        public var differingByteCount: Int64

        public init(range: Range<Int64>, differingByteCount: Int64) {
            self.range = range
            self.differingByteCount = differingByteCount
        }
    }

    /// The most stretches kept before the resolution drops. A person steps through far fewer, and an
    /// overview strip has fewer pixels.
    public static let defaultCapacity = 100_000

    /// In order and never overlapping.
    public private(set) var stretches: [Stretch] = []
    /// Every differing byte seen, exactly.
    public private(set) var differingByteCount: Int64 = 0
    /// Two differing bytes join when fewer than this many equal bytes lie between them. Starts at
    /// the width of a row and doubles each time the list reaches ``capacity``.
    public private(set) var gap: Int64
    public let capacity: Int

    public init(gap: Int64 = Int64(BinaryHexLayout.bytesPerRow), capacity: Int = defaultCapacity) {
        precondition(gap > 0, "a gap of zero would join nothing")
        precondition(capacity >= 2, "a list has to be able to halve")
        self.gap = gap
        self.capacity = capacity
    }

    /// Note every byte where `left` and `right` differ, up to the shorter of the two. Offsets are
    /// `start` plus the position in the buffers, and calls must come in order of offset.
    public mutating func consume(
        _ left: UnsafeRawBufferPointer,
        _ right: UnsafeRawBufferPointer,
        at start: Int64
    ) {
        let count = min(left.count, right.count)
        guard count > 0, let leftBase = left.baseAddress, let rightBase = right.baseAddress,
              memcmp(leftBase, rightBase, count) != 0 else { return }
        let leftBytes = leftBase.assumingMemoryBound(to: UInt8.self)
        let rightBytes = rightBase.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count where leftBytes[index] != rightBytes[index] {
            record(start + Int64(index))
        }
    }

    private mutating func record(_ offset: Int64) {
        differingByteCount += 1
        if let last = stretches.indices.last, offset - stretches[last].range.upperBound < gap {
            stretches[last].range = stretches[last].range.lowerBound..<(offset + 1)
            stretches[last].differingByteCount += 1
            return
        }
        stretches.append(Stretch(range: offset..<(offset + 1), differingByteCount: 1))
        if stretches.count > capacity {
            reduce()
        }
    }

    /// Double the gap until the stretches fit in half of ``capacity``, so a pathological pair pays
    /// for this a logarithmic number of times rather than once per new stretch.
    private mutating func reduce() {
        while stretches.count > capacity / 2 {
            gap *= 2
            var joined = 0
            for index in 1..<stretches.count {
                let next = stretches[index]
                if next.range.lowerBound - stretches[joined].range.upperBound < gap {
                    stretches[joined].range = stretches[joined].range.lowerBound..<next.range.upperBound
                    stretches[joined].differingByteCount += next.differingByteCount
                } else {
                    joined += 1
                    stretches[joined] = next
                }
            }
            stretches.removeLast(stretches.count - joined - 1)
        }
    }
}
