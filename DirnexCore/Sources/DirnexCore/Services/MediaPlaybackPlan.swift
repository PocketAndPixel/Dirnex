import Foundation

/// A track a playback plan chooses among: Matroska's tracks and AVI's streams.
public protocol MediaPlaybackTrack: Equatable, Sendable {
    var isPicture: Bool { get }
    var isSound: Bool { get }
    var isEnabled: Bool { get }
    /// Whether the file marks it as the one to play. AVI has no such mark.
    var isDefault: Bool { get }
}

/// Which of a file's tracks Quick View plays (PLAN.md §M42 ▸ Slice 4): one picture and one sound,
/// among those this Mac can decode.
///
/// The sound is the file's default track when it can be decoded, and otherwise the first that can, so
/// a film whose default is DTS still plays with its AC-3 track rather than in silence. The film on
/// this Mac carries five AC-3 tracks and four DTS ones; its default is AC-3. An AVI marks no default,
/// so its first sound that decodes plays (Slice 5).
public struct MediaPlaybackPlan<Track: MediaPlaybackTrack>: Equatable, Sendable {
    public let video: Track?
    public let audio: Track?
    /// Whether the file has a picture and no picture track can be decoded. Its sound alone would play
    /// a film as a radio play, so nothing plays.
    public let refusesPicture: Bool
    /// The audio tracks, in the file's order, with whether each can be decoded, for naming the ones
    /// that are not played.
    public let audioTracks: [(track: Track, isDecodable: Bool)]

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.video == rhs.video && lhs.audio == rhs.audio && lhs.refusesPicture == rhs.refusesPicture
            && lhs.audioTracks.map(\.track) == rhs.audioTracks.map(\.track)
            && lhs.audioTracks.map(\.isDecodable) == rhs.audioTracks.map(\.isDecodable)
    }

    /// The plan for `tracks`, asking `canDecode` of each picture and sound track that is enabled.
    public init(tracks: [Track], canDecode: (Track) -> Bool) {
        let pictures = tracks.filter { $0.isPicture && $0.isEnabled }
        video = pictures.first(where: canDecode)
        refusesPicture = !pictures.isEmpty && video == nil
        let sounds = tracks.filter { $0.isSound && $0.isEnabled }
            .map { (track: $0, isDecodable: canDecode($0)) }
        audioTracks = sounds
        let decodable = sounds.filter(\.isDecodable).map(\.track)
        audio = decodable.first(where: \.isDefault) ?? decodable.first
    }

    /// Whether there is anything to play.
    public var isPlayable: Bool {
        !refusesPicture && (video != nil || audio != nil)
    }
}

public typealias MatroskaPlaybackPlan = MediaPlaybackPlan<MatroskaTrack>
public typealias AVIPlaybackPlan = MediaPlaybackPlan<AVIStream>

extension MatroskaTrack: MediaPlaybackTrack {
    public var isPicture: Bool { kind == .video }
    public var isSound: Bool { kind == .audio }
}

extension AVIStream: MediaPlaybackTrack {
    public var isPicture: Bool { kind == .video }
    public var isSound: Bool { kind == .audio }
    public var isDefault: Bool { false }
}
