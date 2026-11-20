import Foundation
import Testing

@testable import DirnexCore

/// Which picture and which sound Quick View plays from a Matroska file (PLAN.md §M42 ▸ Slice 4).
@Suite("Matroska playback plan")
struct MatroskaPlaybackPlanTests {
    private func track(
        _ number: UInt64,
        _ kind: MatroskaTrack.Kind,
        _ codec: String,
        isDefault: Bool = false
    )
        -> MatroskaTrack {
        var track = MatroskaTrack()
        track.number = number
        track.kind = kind
        track.codecID = codec
        track.isDefault = isDefault
        return track
    }

    /// Every codec but DTS and VP8, as on this Mac.
    private func decodes(_ track: MatroskaTrack) -> Bool {
        !["A_DTS", "V_VP8"].contains(track.codecID)
    }

    @Test(
        "the film plays its picture and its default AC-3 track, and knows its DTS ones are out of reach"
    )
    func film() throws {
        let file = try MatroskaFile(source: SparseCaptureSource(fixture: "film.mkv"))
        let plan = MatroskaPlaybackPlan(tracks: file.tracks, canDecode: decodes)
        #expect(plan.video?.number == 1)
        #expect(plan.audio?.number == 2)
        #expect(plan.isPlayable && !plan.refusesPicture)
        #expect(plan.audioTracks.map(\.track.number) == Array(2...10))
        #expect(plan.audioTracks.filter { !$0.isDecodable }.map(\.track.number) == [3, 4, 5, 9])
    }

    @Test("a default track nothing decodes gives way to the first that can be")
    func defaultUndecodable() {
        let plan = MatroskaPlaybackPlan(tracks: [
            track(1, .video, "V_MPEG4/ISO/AVC"),
            track(2, .audio, "A_DTS", isDefault: true),
            track(3, .audio, "A_AC3"),
            track(4, .audio, "A_EAC3", isDefault: true)
        ], canDecode: decodes)
        #expect(plan.audio?.number == 4, "a decodable default wins over an earlier track")
        let noDefault = MatroskaPlaybackPlan(tracks: [
            track(2, .audio, "A_DTS", isDefault: true), track(3, .audio, "A_AC3")
        ], canDecode: decodes)
        #expect(noDefault.audio?.number == 3)
    }

    @Test("a picture nothing decodes refuses the file, whatever its sound")
    func undecodablePicture() {
        let plan = MatroskaPlaybackPlan(tracks: [
            track(1, .video, "V_VP8", isDefault: true),
            track(2, .audio, "A_VORBIS", isDefault: true)
        ], canDecode: decodes)
        #expect(plan.refusesPicture && !plan.isPlayable)
        #expect(plan.video == nil && plan.audio?.number == 2)
    }

    @Test(
        "a sound alone plays, a picture with only DTS plays silent, and a disabled track is left out"
    )
    func partial() {
        #expect(
            MatroskaPlaybackPlan(tracks: [track(1, .audio, "A_OPUS")], canDecode: decodes).isPlayable
        )
        let silent = MatroskaPlaybackPlan(tracks: [
            track(1, .video, "V_MPEG4/ISO/AVC"), track(2, .audio, "A_DTS", isDefault: true)
        ], canDecode: decodes)
        #expect(silent.isPlayable && silent.audio == nil)
        var disabled = track(2, .audio, "A_AC3", isDefault: true)
        disabled.isEnabled = false
        let plan = MatroskaPlaybackPlan(
            tracks: [disabled, track(3, .audio, "A_EAC3")],
            canDecode: decodes
        )
        #expect(plan.audio?.number == 3 && plan.audioTracks.count == 1)
        #expect(
            !MatroskaPlaybackPlan(tracks: [track(1, .subtitle, "S_TEXT/UTF8")], canDecode: decodes).isPlayable
        )
    }
}
