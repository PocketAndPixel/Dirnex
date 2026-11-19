import Foundation
import Testing

@testable import DirnexCore

/// A Matroska file's clusters read as an index of samples, and its cues (PLAN.md §M42 ▸ Slice 3).
///
/// Every frame written here holds bytes of its own, and every check of a frame's place reads the frame
/// back through `MatroskaFile.frame(_:of:)`: an offset that is off by one reads the wrong bytes, where
/// comparing it with an offset computed the same way would agree with itself.
@Suite("Matroska clusters and cues")
struct MatroskaClusterTests {
    /// Frames of the sizes lacing has to get right: an empty one, a run of exactly 255 for Xiph, sizes
    /// either side of it, and differences that need one and two bytes in EBML lacing.
    static let frameSizes = [3, 255, 0, 510, 256, 40, 1000, 1]

    static func frames(_ sizes: [Int], seed: UInt8 = 1) -> [[UInt8]] {
        sizes.enumerated().map { index, size in
            (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ index &* 31 &+ Int(seed)) }
        }
    }

    private func open(_ clusters: [[UInt8]], tracks: [UInt8] = MKV.plainTracks) throws -> MatroskaFile {
        try MatroskaFile(source: MKV.file([MKV.info(), tracks] + clusters))
    }

    private func firstCluster(_ file: MatroskaFile) throws -> MatroskaCluster {
        let offset = try #require(file.firstClusterOffset)
        return try #require(try file.cluster(from: offset))
    }

    @Test(
        "each lacing divides a block into the frames that were written",
        arguments: MKV.Lacing.allCases
    )
    func lacing(_ lacing: MKV.Lacing) throws {
        let written = lacing == .fixed ? Self.frames(Array(repeating: 300, count: 6))
            : lacing == .none ? Self.frames([777]) : Self.frames(Self.frameSizes)
        let file = try open([MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 2, time: 0, lacing: lacing, frames: written)
        ])])
        let block = try #require(try firstCluster(file).blocks.first)
        #expect(block.frames.count == written.count)
        let read = try block.frames.indices.map { try [UInt8](file.frame($0, of: block)) }
        #expect(read == written)
    }

    @Test("a laced frame's time steps by the track's default duration, and is unknown without one")
    func lacedTimes() throws {
        let tracks = MKV.tracks([
            MKV.track(1, type: 2, codec: "A_DTS"),
            MKV.track(2, type: 2, codec: "A_AC3", [EBMLWriter.uint(0x23E383, 32_000_000)])
        ])
        let file = try open([MKV.cluster(time: 1000, [
            MKV.simpleBlock(track: 2, time: 5, lacing: .fixed, frames: Self.frames([4, 4, 4])),
            MKV.simpleBlock(track: 1, time: 5, lacing: .fixed, frames: Self.frames([4, 4]))
        ])], tracks: tracks)
        let blocks = try firstCluster(file).blocks
        #expect(
            (0..<3).map { file.frameTime($0, of: blocks[0]) } == [
                1_005_000_000,
                1_037_000_000,
                1_069_000_000
            ]
        )
        #expect(file.frameTime(0, of: blocks[1]) == 1_005_000_000)
        #expect(
            file.frameTime(1, of: blocks[1]) == nil,
            "DTS frames' lengths are the codec's to say"
        )
    }

    @Test("a SimpleBlock's flags say keyframe, invisible and discardable")
    func simpleFlags() throws {
        let file = try open([MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, flags: 0x80, frames: [[1]]),
            MKV.simpleBlock(track: 1, time: 40, flags: 0x00, frames: [[2]]),
            MKV.simpleBlock(track: 1, time: 80, flags: 0x08 | 0x01, frames: [[3]])
        ])])
        let blocks = try firstCluster(file).blocks
        #expect(blocks.map(\.isKeyframe) == [true, false, false])
        #expect(blocks.map(\.isInvisible) == [false, false, true])
        #expect(blocks.map(\.isDiscardable) == [false, false, true])
    }

    /// Lavf wrote every VP9 frame with alpha as a `BlockGroup`, a key frame being one with no
    /// `ReferenceBlock` (seen 2026-11-20 in Steam's WebMs); subtitles carry a `BlockDuration`.
    @Test("a BlockGroup is a keyframe unless it names a reference, with its duration and padding")
    func blockGroups() throws {
        let file = try open([MKV.cluster(time: 100, [
            MKV.blockGroup(track: 1, time: 0, frame: [0xAA, 0xBB]),
            MKV.blockGroup(track: 1, time: 67, frame: [0xCC], reference: -67),
            MKV.blockGroup(track: 2, time: -20, frame: [0xDD], duration: 2376, padding: 6_500_000)
        ])])
        let blocks = try firstCluster(file).blocks
        #expect(blocks.map(\.isKeyframe) == [true, false, true])
        #expect(blocks.map(\.timestamp) == [100, 167, 80], "a block may start before its cluster")
        #expect(blocks[2].duration == 2376)
        #expect(blocks[2].discardPadding == 6_500_000)
        #expect(try file.frame(0, of: blocks[0]) == Data([0xAA, 0xBB]))
        #expect(try file.frame(0, of: blocks[1]) == Data([0xCC]))
    }

    @Test("a cluster's time applies to its blocks even when written after them")
    func lateTimestamp() throws {
        let block = MKV.simpleBlock(track: 1, time: 10, frames: [[1]])
        let cluster = EBMLWriter.parent(0x1F43B675, [block, EBMLWriter.uint(0xE7, 500)])
        let blocks = try firstCluster(open([cluster])).blocks
        #expect(blocks.first?.timestamp == 510)
    }

    @Test("header stripping puts the stripped bytes back on every frame; zlib frames are refused")
    func strippedFrames() throws {
        let tracks = MKV.tracks([
            MKV.track(
                1,
                type: 2,
                codec: "A_AC3",
                [MKV.compression(algorithm: 3, settings: [0x0B, 0x77])]
            ),
            MKV.track(2, type: 0x11, codec: "S_HDMV/PGS", [MKV.compression(algorithm: nil)])
        ])
        let file = try open([MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, lacing: .xiph, frames: [[1, 2], [3]]),
            MKV.simpleBlock(track: 2, time: 0, frames: [[0x78, 0x9C]])
        ])], tracks: tracks)
        let blocks = try firstCluster(file).blocks
        #expect(try file.frame(0, of: blocks[0]) == Data([0x0B, 0x77, 1, 2]))
        #expect(try file.frame(1, of: blocks[0]) == Data([0x0B, 0x77, 3]))
        #expect(throws: MatroskaError.unreadableFrames(track: 2)) { try file.frame(0, of: blocks[1]) }
    }

    // MARK: - From cluster to cluster

    @Test("clusters follow one another, past what lies between them, to nothing after the last")
    func walk() throws {
        let file = try open([
            MKV.cluster(time: 0, [MKV.simpleBlock(track: 1, time: 0, frames: [[1]])]),
            MKV.void(30),
            EBMLWriter.parent(0x1254C367, []),
            MKV.cluster(
                time: 1000,
                [MKV.simpleBlock(track: 1, time: 0, frames: [[2]])],
                size: .eight
            ),
            MKV.cues([(0, [(1, 0)])])
        ])
        let first = try firstCluster(file)
        let next = try #require(first.nextOffset)
        let second = try #require(try file.cluster(from: next))
        #expect(second.timestamp == 1000)
        let block = try #require(second.blocks.first)
        #expect(try file.frame(0, of: block) == Data([2]))
        let after = try #require(second.nextOffset, "the cues follow")
        #expect(try file.cluster(from: after) == nil)
    }

    /// Chrome's `MediaRecorder` writes the segment and every cluster before knowing their sizes. Not
    /// met in a real file on this Mac; RFC 8794 §6.2 is the rule.
    @Test(
        "a cluster of unknown size ends where the next one begins, and the last at the end of the file"
    )
    func unknownSizes() throws {
        let file = try MatroskaFile(source: MKV.file(segmentSize: .unknown, [
            MKV.info(), MKV.plainTracks,
            MKV.cluster(time: 0, [
                MKV.simpleBlock(track: 1, time: 0, frames: [[1, 1]]),
                MKV.simpleBlock(track: 2, time: 0, lacing: .ebml, frames: Self.frames([5, 300, 2]))
            ], size: .unknown),
            MKV.cluster(
                time: 2000,
                [MKV.simpleBlock(track: 1, time: 0, frames: [[2, 2]])],
                size: .unknown
            )
        ]))
        let first = try firstCluster(file)
        #expect(first.blocks.count == 2)
        #expect(!first.isTruncated)
        let next = try #require(first.nextOffset)
        let second = try #require(try file.cluster(from: next))
        #expect(second.timestamp == 2000)
        let block = try #require(second.blocks.first)
        #expect(try file.frame(0, of: block) == Data([2, 2]))
        #expect(second.nextOffset == nil)
        #expect(!second.isTruncated)
        #expect(try file.cues().isEmpty)
    }

    @Test("a file cut inside a cluster gives the blocks that were whole, and says it was cut")
    func truncatedCluster() throws {
        let source = MKV.file([MKV.info(), MKV.plainTracks, MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, frames: [[1, 2, 3]]),
            MKV.simpleBlock(track: 1, time: 40, frames: [Array(repeating: 9, count: 50)])
        ])])
        for cut in [10, 52] {
            let file = try MatroskaFile(
                source: DataByteSource(source.data.prefix(source.data.count - cut))
            )
            let cluster = try firstCluster(file)
            #expect(cluster.isTruncated)
            #expect(cluster.nextOffset == nil)
            #expect(cluster.blocks.count == 1, "cut \(cut) bytes from the end")
        }
    }

    @Test("lace sizes adding up to more than the block, or not dividing it, are malformed")
    func badLacing() throws {
        // Xiph sizes of 255 + 255 + 10 for a block holding 20 bytes of frames.
        let xiph = EBMLWriter.element(
            0xA3,
            [0x81, 0x00, 0x00, 0x82, 0x01, 255, 255, 10] + Array(repeating: 0, count: 20)
        )
        // Fixed lacing of 3 frames over 10 bytes.
        let fixed = EBMLWriter.element(
            0xA3,
            [0x81, 0x00, 0x00, 0x84, 0x02] + Array(repeating: 0, count: 10)
        )
        for block in [xiph, fixed] {
            let file = try open([MKV.cluster(time: 0, [block])])
            let offset = try #require(file.firstClusterOffset)
            #expect(throws: MatroskaError.self) { try file.cluster(from: offset) }
        }
    }

    // MARK: - Cues

    @Test("cues name clusters by where they are in the file, in time order")
    func cues() throws {
        let clusters = [
            MKV.cluster(time: 0, [MKV.simpleBlock(track: 1, time: 0, frames: [[1]])]),
            MKV.cluster(time: 5000, [MKV.simpleBlock(track: 1, time: 0, frames: [[2]])]),
            MKV.cluster(time: 9000, [MKV.simpleBlock(track: 2, time: 0, frames: [[3]])])
        ]
        // The SeekHead names the cues after the clusters, as every muxer seen does.
        let head = [MKV.seekHead([(0x1C53BB6B, 0)]), MKV.info(), MKV.plainTracks]
        let at = MKV.positions(head + clusters + [[]])
        // Written out of order, and with one point naming two tracks.
        let cues = MKV.cues(
            [(5000, [(1, at[4])]), (0, [(1, at[3]), (2, at[3])]), (9000, [(2, at[5])])]
        )
        let children = [MKV.seekHead([(0x1C53BB6B, at[6])])] + head.dropFirst() + clusters + [cues]
        let file = try MatroskaFile(source: MKV.file(children))
        let base = MKV.segmentDataOffset(children)
        let read = try file.cues()
        try #require(read.map(\.time) == [0, 5000, 9000])
        #expect(read[0].positions.map(\.track) == [1, 2])
        #expect(read[1].positions.first?.clusterOffset == base + at[4])
        let cluster = try #require(try file.cluster(from: read[1].positions[0].clusterOffset))
        #expect(cluster.timestamp == 5000)

        let lookup = { (ticks: Int64, track: UInt64) in MatroskaFile.cue(
            atOrBefore: ticks,
            track: track,
            in: read
        )?.time }
        #expect(lookup(5000, 1) == 5000, "a cue exactly at the target")
        #expect(lookup(8999, 1) == 5000, "the last before it")
        #expect(lookup(60000, 1) == 5000, "past the last cue for the track")
        #expect(lookup(8999, 2) == 0, "track 2 is cued at 0 and 9000 only")
        #expect(lookup(9000, 2) == 9000)
        #expect(lookup(-1, 1) == nil)
        #expect(MatroskaFile.cue(atOrBefore: 100, track: 1, in: []) == nil)
    }

    @Test("cues the file ends inside are truncated")
    func truncatedCues() throws {
        // Cues before the first cluster are found by the walk; mkvmerge can be asked to write them there.
        let cues = MKV.cues((0..<20).map { (UInt64($0) * 1000, [(1, 0)]) })
        let whole = MKV.file([MKV.info(), MKV.plainTracks, cues])
        let file = try MatroskaFile(source: DataByteSource(whole.data.prefix(whole.data.count - 5)))
        #expect(file.cuesOffset != nil)
        #expect(throws: MatroskaError.truncated) { try file.cues() }
    }
}
