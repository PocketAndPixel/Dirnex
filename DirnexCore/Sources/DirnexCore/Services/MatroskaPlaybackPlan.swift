import Foundation

/// Which of a Matroska file's tracks Quick View plays (PLAN.md §M42 ▸ Slice 4): one picture and one
/// sound, among those this Mac can decode.
///
/// The sound is the file's default track when it can be decoded, and otherwise the first that can, so
/// a film whose default is DTS still plays with its AC-3 track rather than in silence. The film on
/// this Mac carries five AC-3 tracks and four DTS ones; its default is AC-3.
public struct MatroskaPlaybackPlan: Equatable, Sendable {
    public let video: MatroskaTrack?
    public let audio: MatroskaTrack?
    /// Whether the file has a picture and no picture track can be decoded. Its sound alone would play
    /// a film as a radio play, so nothing plays.
    public let refusesPicture: Bool
    /// The audio tracks, in the file's order, with whether each can be decoded, for naming the ones
    /// that are not played.
    public let audioTracks: [(track: MatroskaTrack, isDecodable: Bool)]

    public static func == (lhs: MatroskaPlaybackPlan, rhs: MatroskaPlaybackPlan) -> Bool {
        lhs.video == rhs.video && lhs.audio == rhs.audio && lhs.refusesPicture == rhs.refusesPicture
            && lhs.audioTracks.map(\.track) == rhs.audioTracks.map(\.track)
            && lhs.audioTracks.map(\.isDecodable) == rhs.audioTracks.map(\.isDecodable)
    }

    /// The plan for `tracks`, asking `canDecode` of each picture and sound track that is enabled.
    public init(tracks: [MatroskaTrack], canDecode: (MatroskaTrack) -> Bool) {
        let pictures = tracks.filter { $0.kind == .video && $0.isEnabled }
        video = pictures.first(where: canDecode)
        refusesPicture = !pictures.isEmpty && video == nil
        let sounds = tracks.filter { $0.kind == .audio && $0.isEnabled }
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
