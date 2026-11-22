import Foundation
import Testing

@testable import DirnexCore

/// Packets handed out a track at a time, and seeking (PLAN.md §M42 ▸ Slice 4).
///
/// Every frame here holds bytes of its own, so a packet is identified by what it carries rather than
/// by a position computed the way the demuxer computes it.
@Suite("Matroska demuxer")
struct MatroskaDemuxerTests {
    /// H.264 at 25 frames a second (40 ms), and AC-3 at 32 ms a packet.
    static let tracks = MKV.tracks([
        MKV.track(1, type: 1, codec: "V_MPEG4/ISO/AVC", [
            MKV.video(width: 64, height: 64), EBMLWriter.uint(0x23E383, 40_000_000)
        ]),
        MKV.track(2, type: 2, codec: "A_AC3", [
            EBMLWriter.parent(0xE1, [EBMLWriter.float(0xB5, 48000), EBMLWriter.uint(0x9F, 2)])
        ])
    ])

    /// A cluster at `seconds` with a picture every 40 ms (a key frame first when `key`) and a sound
    /// block of three laced 32 ms packets every 96 ms, so the sound runs the whole second, each frame's
    /// bytes naming its track and time.
    static func cluster(at seconds: Int, key: Bool = true, pictures: Int = 25) -> [UInt8] {
        let base = UInt64(seconds * 1000)
        var blocks: [(time: Int, bytes: [UInt8])] = []
        for index in 0..<pictures {
            let time = index * 40
            blocks.append((time, MKV.simpleBlock(
                track: 1,
                time: Int16(time),
                flags: index == 0 && key ? 0x80 : 0,
                frames: [frame(1, base + UInt64(time))]
            )))
        }
        for index in 0..<10 {
            let start = index * 96
            blocks.append((start, MKV.simpleBlock(
                track: 2,
                time: Int16(start),
                lacing: .fixed,
                frames: (0..<3).map { frame(2, base + UInt64(start + $0 * 32)) }
            )))
        }
        return MKV.cluster(time: base, blocks.sorted { $0.time < $1.time }.map(\.bytes))
    }

    /// Eight bytes: the track, then the time in milliseconds.
    static func frame(_ track: UInt8, _ milliseconds: UInt64) -> [UInt8] {
        [track, 0, 0, 0] + withUnsafeBytes(of: UInt32(milliseconds).bigEndian, Array.init)
    }

    static func milliseconds(_ packet: MediaPacket) -> UInt64 {
        packet.data.suffix(4).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// A file of `clusters`, with a cue for each cluster's picture at its whole second when `cues`,
    /// kept after the clusters and named by a `SeekHead`, as mkvmerge lays a file out. The `SeekHead`
    /// writes its position in eight bytes, so it is the same size before and after the position is
    /// known.
    private func open(_ clusters: [[UInt8]], cues: Bool = false) throws -> MatroskaFile {
        guard cues else { return try MatroskaFile(
            source: MKV.file([MKV.info(), Self.tracks] + clusters)
        ) }
        let head = [MKV.seekHead([(0x1C53BB6B, 0)]), MKV.info(), Self.tracks]
        let positions = MKV.positions(head + clusters)
        let points = clusters.indices.map { index in
            (UInt64(index * 1000), [(UInt64(1), positions[head.count + index])])
        }
        let cuesPosition = positions.last! + UInt64(clusters.last!.count)
        let children = [MKV.seekHead([(0x1C53BB6B, cuesPosition)])] + head.dropFirst() + clusters + [
            MKV.cues(points)
        ]
        return try MatroskaFile(source: MKV.file(children))
    }

    private func demuxer(_ file: MatroskaFile) -> MatroskaDemuxer {
        MatroskaDemuxer(file: file, tracks: file.tracks)
    }

    @Test("each track comes out in its own order, the other's packets waiting for it")
    func perTrackOrder() throws {
        let file = try open([Self.cluster(at: 0), Self.cluster(at: 1)])
        var demuxer = demuxer(file)
        var pictures: [UInt64] = []
        while let packet = try demuxer.next(track: 1) { pictures.append(Self.milliseconds(packet)) }
        #expect(pictures == (0..<50).map { UInt64($0 * 40) })
        var sounds: [MediaPacket] = []
        while let packet = try demuxer.next(track: 2) { sounds.append(packet) }
        var expected: [UInt64] = []
        for second in 0..<2 {
            for index in 0..<30 { expected.append(UInt64(second * 1000 + index * 32)) }
        }
        #expect(sounds.map(Self.milliseconds) == expected)
        let stated: [Int64] = sounds.map { Int64(Self.milliseconds($0)) * 1_000_000 }
        #expect(sounds.map(\.time) == stated)
        #expect(sounds.allSatisfy { $0.duration == 32_000_000 })
        #expect(sounds.allSatisfy { $0.track == 2 && $0.frameCount == nil && !$0.isPreroll })
        #expect(try demuxer.next(track: 1) == nil, "the end stays the end")
        #expect(try demuxer.next(track: 7) == nil, "a track not being played")
    }

    @Test("a laced frame with no default duration is timed by its codec's packet length")
    func codecStep() throws {
        let tracks = MKV.tracks([MKV.track(1, type: 2, codec: "A_DTS", [
            EBMLWriter.parent(0xE1, [EBMLWriter.float(0xB5, 48000)])
        ])])
        let file = try MatroskaFile(source: MKV.file([MKV.info(), tracks, MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, lacing: .fixed, frames: [[1], [2], [3]])
        ])]))
        var demuxer = MatroskaDemuxer(file: file, tracks: file.tracks)
        var times: [Int64] = []
        while let packet = try demuxer.next(track: 1) { times.append(packet.time) }
        // 512 frames at 48 kHz.
        #expect(times == [0, 10_666_667, 21_333_334])
    }

    @Test("a seek by the cues starts at the cue's cluster, pictures before the target as preroll")
    func seekWithCues() throws {
        let file = try open((0..<4).map { Self.cluster(at: $0) }, cues: true)
        let cues = try file.cues()
        #expect(cues.map(\.time) == [0, 1000, 2000, 3000])
        var demuxer = demuxer(file)
        _ = try demuxer.next(track: 1)
        try demuxer.seek(to: 2_500_000_000, cues: cues, keyTrack: 1)
        var pictures: [MediaPacket] = []
        for _ in 0..<15 { pictures.append(try #require(try demuxer.next(track: 1))) }
        #expect(pictures.map(Self.milliseconds) == (0..<15).map { UInt64(2000 + $0 * 40) })
        #expect(pictures.map(\.isPreroll) == Array(repeating: true, count: 13) + [false, false])
        #expect(pictures.first?.isKeyframe == true)
        let sound = try #require(try demuxer.next(track: 2))
        // The packet at 2.480 s plays to 2.512 s, past the target, so it is the first one kept.
        #expect(Self.milliseconds(sound) == 2480)
        #expect(!sound.isPreroll)
    }

    @Test(
        "with no cues a seek walks to the last cluster at or before the target that starts a picture"
    )
    func seekByWalking() throws {
        let clusters = [
            Self.cluster(at: 0),
            Self.cluster(at: 1),
            Self.cluster(at: 2, key: false),
            Self.cluster(at: 3)
        ]
        let file = try open(clusters)
        var demuxer = demuxer(file)
        try demuxer.seek(to: 2_200_000_000, cues: [], keyTrack: 1)
        let first = try #require(try demuxer.next(track: 1))
        #expect(Self.milliseconds(first) == 1000, "the cluster at 2 s has no key frame")
        try demuxer.seek(to: 3_100_000_000, cues: [], keyTrack: 1)
        #expect(try demuxer.next(track: 1).map(Self.milliseconds) == 3000)
        try demuxer.seek(to: 99_000_000_000, cues: [], keyTrack: 1)
        #expect(
            try demuxer.next(track: 1).map(Self.milliseconds) == 3000,
            "past the end: the last key frame"
        )
    }

    @Test("after a seek, pictures before the next key frame are passed over")
    func keyframeAfterSeek() throws {
        // The cue names a cluster whose first frames depend on ones before it.
        let file = try open(
            [Self.cluster(at: 0), Self.cluster(at: 1, key: false), Self.cluster(at: 2)],
            cues: true
        )
        var demuxer = demuxer(file)
        try demuxer.seek(to: 1_500_000_000, cues: try file.cues(), keyTrack: 1)
        let first = try #require(try demuxer.next(track: 1))
        #expect(Self.milliseconds(first) == 2000)
        #expect(first.isKeyframe && !first.isPreroll)
    }

    @Test("Opus packets carry their frame counts and the lengths those make")
    func opusCounts() throws {
        let head = Data("OpusHead".utf8) + Data([1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0])
        let tracks = MKV.tracks(
            [MKV.track(1, type: 2, codec: "A_OPUS", [EBMLWriter.element(0x63A2, [UInt8](head))])]
        )
        let file = try MatroskaFile(source: MKV.file([MKV.info(), tracks, MKV.cluster(time: 0, [
            MKV.simpleBlock(track: 1, time: 0, frames: [[0xFC, 1]]),
            MKV.simpleBlock(track: 1, time: 20, frames: [[0xF4, 2]]),
            MKV.simpleBlock(track: 1, time: 30, frames: [[0x19, 3]])
        ])]))
        var demuxer = MatroskaDemuxer(file: file, tracks: file.tracks)
        var packets: [MediaPacket] = []
        while let packet = try demuxer.next(track: 1) { packets.append(packet) }
        #expect(packets.map(\.frameCount) == [960, 480, 5760])
        #expect(packets.map(\.duration) == [20_000_000, 10_000_000, 120_000_000])
    }

    @Test("the first key frame is found past frames that are not one")
    func firstKeyframe() throws {
        let file = try open([Self.cluster(at: 0, key: false), Self.cluster(at: 1)])
        let key = try #require(try file.firstKeyframe(track: 1))
        #expect(key == Data(Self.frame(1, 1000)))
        #expect(try file.firstKeyframe(track: 9) == nil)
    }

    @Test("the film's first cluster: AC-3 laced eight to a block, DTS timed by its codec")
    func filmCluster() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "film.mkv"))
        let tracks = try [1, 2, 3].map { try #require(file.track(number: $0)) }
        var demuxer = MatroskaDemuxer(file: file, tracks: tracks)
        let ac3 = try (0..<16).map { _ in try #require(try demuxer.next(track: 2)) }
        #expect(ac3.map(\.time) == (0..<16).map { Int64($0) * 32_000_000 })
        #expect(ac3.allSatisfy { $0.data.prefix(2) == Data([0x0B, 0x77]) })
        let dts = try (0..<3).map { _ in try #require(try demuxer.next(track: 3)) }
        #expect(dts.map(\.time) == [0, 10_666_667, 21_333_334])
        #expect(dts.allSatisfy { $0.data.prefix(4) == Data([0x7F, 0xFE, 0x80, 0x01]) })
        let picture = try #require(try demuxer.next(track: 1))
        #expect(picture.isKeyframe && picture.time == 0)
        #expect(picture.duration == 41_708_332)
    }
}
