import Foundation

/// What a player asks of a container's reader (PLAN.md §M42 ▸ Slices 4 and 5): each track's packets in
/// its own order, and a seek. Matroska's and AVI's demuxers both answer it, so one player plays both.
public protocol MediaDemuxing: Sendable {
    /// The next packet of `track`, or `nil` once the file has no more of it.
    mutating func next(track: UInt64) throws -> MediaPacket?

    /// Start again at `nanoseconds`: pictures at the key frame of `keyTrack` before it, those before
    /// the target coming back as preroll, and sound that ends before it not at all.
    mutating func seek(to nanoseconds: Int64, keyTrack: UInt64?) throws
}

extension AVIDemuxer: MediaDemuxing {
    /// Each AVI stream finds its own key frame in its own index, so `keyTrack` is not needed.
    public mutating func seek(to nanoseconds: Int64, keyTrack _: UInt64?) throws {
        seek(to: nanoseconds)
    }
}

extension MatroskaDemuxer: MediaDemuxing {}
