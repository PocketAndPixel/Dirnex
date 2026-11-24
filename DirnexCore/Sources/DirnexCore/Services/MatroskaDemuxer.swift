import Foundation

/// One frame of a track as a decoder takes it (PLAN.md §M42 ▸ Slice 4): its bytes, when it plays and
/// for how long.
public struct MediaPacket: Equatable, Sendable {
    public let track: UInt64
    /// When it plays, in nanoseconds of the file's clock.
    public let time: Int64
    /// How long it plays, in nanoseconds, when the file or the codec says.
    public let duration: Int64?
    public let data: Data
    public let isKeyframe: Bool
    /// Frames of sound in it, for the codecs whose packets differ (`MediaFrameCounter`).
    public let frameCount: Int?
    /// A picture before a seek's target: decoded, since the pictures after it are made from it, and
    /// not shown.
    public let isPreroll: Bool

    public init(
        track: UInt64,
        time: Int64,
        duration: Int64?,
        data: Data,
        isKeyframe: Bool,
        frameCount: Int?,
        isPreroll: Bool
    ) {
        self.track = track
        self.time = time
        self.duration = duration
        self.data = data
        self.isKeyframe = isKeyframe
        self.frameCount = frameCount
        self.isPreroll = isPreroll
    }
}

/// Hands out the packets of the tracks being played, each track in its own order, reading the file a
/// cluster at a time (PLAN.md §M42 ▸ Slice 4).
///
/// A Matroska file interleaves its tracks in clusters, while a player feeds its picture and its sound
/// to two renderers that each ask when they have room. So a cluster read for one track leaves the other
/// tracks' blocks waiting here until theirs asks. Muxers interleave within a second or two (mkvmerge's
/// clusters in the film run five seconds at most), which is how much waits.
public struct MatroskaDemuxer: Sendable {
    public let file: MatroskaFile
    private var states: [UInt64: TrackState]
    private var nextCluster: UInt64?
    /// Where the last seek wants playback to start, in nanoseconds. Packets before it are preroll or
    /// passed over; the ones after it never meet it again.
    private var target: Int64?
    /// The cues, read on the first seek: the film's lie 10 GB along and cost a millisecond, which a
    /// cursor passing over the file should not pay.
    private var cues: [MatroskaCuePoint]?

    /// How each track is timed and counted.
    private struct TrackState: Sendable {
        let track: MatroskaTrack
        let counter: MediaFrameCounter?
        /// How long one packet lasts when they all last the same: the track's default duration, or
        /// the codec's frames per packet.
        let step: Int64?
        let sampleRate: Double?
        var queue: [MediaPacket] = []
        var head = 0
        var previousBlock: Int?
        /// Set by a seek on a picture track: frames before the next key frame depend on frames the
        /// decoder never saw, so they are passed over.
        var awaitsKeyframe = false
    }

    /// A demuxer for `tracks` of `file`, at the first cluster.
    public init(file: MatroskaFile, tracks: [MatroskaTrack]) {
        self.file = file
        nextCluster = file.firstClusterOffset
        var states: [UInt64: TrackState] = [:]
        for track in tracks {
            let audio = track.kind == .audio ? track.sampleFormat().flatMap { format -> MediaSampleFormat.Audio? in
                if case let .audio(audio) = format { return audio }
                return nil
            } : nil
            states[track.number] = TrackState(
                track: track,
                counter: MediaFrameCounter(track),
                step: track.defaultDuration.map { Int64(clamping: $0) } ?? audio?.packetDuration,
                sampleRate: audio?.sampleRate
            )
        }
        self.states = states
    }

    /// The next packet of `track`, or `nil` once the file has no more of it.
    public mutating func next(track: UInt64) throws -> MediaPacket? {
        guard states[track] != nil else { return nil }
        while states[track]!.head == states[track]!.queue.count {
            guard let offset = nextCluster, let cluster = try file.cluster(from: offset) else {
                nextCluster = nil
                return nil
            }
            nextCluster = cluster.nextOffset
            try take(cluster)
        }
        let packet = states[track]!.queue[states[track]!.head]
        states[track]!.head += 1
        if states[track]!.head > 256 {
            states[track]!.queue.removeFirst(states[track]!.head)
            states[track]!.head = 0
        }
        return packet
    }

    /// Start again at `nanoseconds`, reading the file's cues the first time (`seek(to:cues:keyTrack:)`).
    /// A file whose cues cannot be read is sought by walking its clusters.
    public mutating func seek(to nanoseconds: Int64, keyTrack: UInt64?) throws {
        if cues == nil { cues = (try? file.cues()) ?? [] }
        try seek(to: nanoseconds, cues: cues ?? [], keyTrack: keyTrack)
    }

    /// Start again at the cluster to read for `nanoseconds`: the one the last cue at or before it names
    /// for `keyTrack` (the picture, whose key frames the cues mark), or, with no cues, the last cluster
    /// at or before it holding one of `keyTrack`'s key frames. Pictures before the target come back as
    /// preroll, and sound that ends before it does not come back at all.
    public mutating func seek(to nanoseconds: Int64, cues: [MatroskaCuePoint], keyTrack: UInt64?) throws {
        let target = max(0, nanoseconds)
        let scale = Int64(clamping: max(1, file.info.timestampScale))
        let ticks = target / scale
        if !cues.isEmpty, let track = keyTrack ?? states.keys.min() {
            nextCluster = MatroskaFile.cue(atOrBefore: ticks, track: track, in: cues)?.position.clusterOffset
                ?? file.firstClusterOffset
        } else {
            nextCluster = try clusterByWalking(to: target, keyTrack: keyTrack)
        }
        self.target = target
        for number in states.keys {
            states[number]!.queue = []
            states[number]!.head = 0
            states[number]!.previousBlock = nil
            states[number]!.awaitsKeyframe = states[number]!.track.kind == .video
        }
    }

    /// The last cluster at or before `target` that starts a picture, found by reading every cluster's
    /// blocks from the first, which is what a file with no cues leaves (a live recording's).
    private func clusterByWalking(to target: Int64, keyTrack: UInt64?) throws -> UInt64? {
        var best = file.firstClusterOffset
        var offset = file.firstClusterOffset
        while let at = offset, let cluster = try file.cluster(from: at) {
            guard file.nanoseconds(ticks: Int64(clamping: cluster.timestamp)) <= target else { break }
            if keyTrack == nil || cluster.blocks.contains(
                where: { $0.track == keyTrack && $0.isKeyframe }
            ) {
                best = cluster.offset
            }
            offset = cluster.nextOffset
        }
        return best
    }

    /// Queue the frames of `cluster` that belong to the tracks being played.
    private mutating func take(_ cluster: MatroskaCluster) throws {
        for block in cluster.blocks {
            guard var state = states[block.track] else { continue }
            if state.awaitsKeyframe {
                guard block.isKeyframe else { continue }
                state.awaitsKeyframe = false
            }
            for index in block.frames.indices {
                guard let packet = try packet(index, of: block, state: &state) else { continue }
                state.queue.append(packet)
            }
            states[block.track] = state
        }
    }

    private func packet(_ index: Int, of block: MatroskaBlock, state: inout TrackState) throws -> MediaPacket? {
        let start = file.nanoseconds(ticks: block.timestamp)
        let time: Int64
        if let stated = file.frameTime(index, of: block) {
            time = stated
        } else if let step = state.step {
            time = start &+ step &* Int64(index)
        } else {
            return nil
        }
        let data = try file.frame(index, of: block)
        var frameCount: Int?
        if let counter = state.counter, let counted = counter.frames(
            in: data,
            previousBlock: state.previousBlock
        ) {
            frameCount = counted.frames
            state.previousBlock = counted.block
        }
        let duration = frameCount.flatMap { frames in
            state.sampleRate.map { Int64((Double(frames) * 1_000_000_000 / $0).rounded()) }
        } ?? state.step ?? block.duration.map { file.nanoseconds(ticks: Int64(clamping: $0)) }
        var isPreroll = false
        if let target, time < target {
            if state.track.kind == .video {
                isPreroll = true
            } else if time &+ (duration ?? 0) <= target {
                return nil
            }
        }
        return MediaPacket(
            track: block.track,
            time: time,
            duration: duration,
            data: data,
            isKeyframe: block.isKeyframe,
            frameCount: frameCount,
            isPreroll: isPreroll
        )
    }
}

extension MatroskaFile {
    /// The first key frame of `track`, from the first `clusters` clusters, which is where every file
    /// seen starts its picture: VP9's configuration is read from it (`VP9FrameHeader`).
    public func firstKeyframe(track: UInt64, searching clusters: Int = 8) throws -> Data? {
        var offset = firstClusterOffset
        for _ in 0..<clusters {
            guard let at = offset, let cluster = try cluster(from: at) else { return nil }
            if let block = cluster.blocks.first(where: { $0.track == track && $0.isKeyframe }),
               !block.frames.isEmpty {
                return try frame(0, of: block)
            }
            offset = cluster.nextOffset
        }
        return nil
    }

    /// The first key frame of each of `tracks`, read in one pass over the first `clusters` clusters:
    /// DTS's layout is read from its first frame, and a film can carry four DTS tracks.
    public func firstKeyframes(tracks: Set<UInt64>, searching clusters: Int = 8) throws -> [
        UInt64: Data
    ] {
        var found: [UInt64: Data] = [:]
        var offset = firstClusterOffset
        for _ in 0..<clusters where found.count < tracks.count {
            guard let at = offset, let cluster = try cluster(from: at) else { break }
            for block in cluster.blocks where tracks.contains(block.track) && found[block.track] == nil
                && block.isKeyframe && !block.frames.isEmpty {
                found[block.track] = try frame(0, of: block)
            }
            offset = cluster.nextOffset
        }
        return found
    }
}
