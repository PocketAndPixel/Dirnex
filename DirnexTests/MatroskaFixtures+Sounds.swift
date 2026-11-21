import AVFoundation
import Foundation

/// Films with several sounds, for the sound track tests (PLAN.md §M42 ▸ Sound tracks), in a file of
/// their own so `MatroskaFixtures` stays under SwiftLint's `type_body_length`.
extension MatroskaFixtures {
    /// One sound of `writeFilm`: AAC or Opus, in a language, the file's default or not.
    struct Sound {
        let codecID: String
        let language: String
        var isDefault = false
    }

    /// An H.264 Matroska file `seconds` long with `sounds` beside it, numbered from 2 in order, each of
    /// silence (PLAN.md §M42 ▸ Sound tracks).
    nonisolated static func writeFilm(to url: URL, seconds: Int = 1, sounds: [Sound]) async throws {
        let mp4 = url.deletingPathExtension().appendingPathExtension("source.mp4")
        defer { try? FileManager.default.removeItem(at: mp4) }
        try await QuickViewMediaFixtures.writeMovie(to: mp4, seconds: seconds)
        var tracks = [try await h264Track(from: mp4)]
        for (offset, sound) in sounds.enumerated() {
            var track = try soundTrack(sound.codecID, number: UInt64(2 + offset), seconds: seconds)
            track.language = sound.language
            track.isDefault = sound.isDefault
            tracks.append(track)
        }
        try write(tracks, duration: Double(seconds), to: url)
    }

    /// A track of silence in `codecID`: AAC or Opus as AudioToolbox encodes them, or DTS with no
    /// packets, which no decoder here would read.
    nonisolated private static func soundTrack(
        _ codecID: String,
        number: UInt64,
        seconds: Int
    ) throws -> Track {
        guard codecID != "A_DTS" else {
            return Track(
                number: number,
                isVideo: false,
                codecID: codecID,
                codecPrivate: nil,
                packets: []
            )
        }
        let isOpus = codecID == "A_OPUS"
        let encoded = try encode(
            isOpus ? kAudioFormatOpus : kAudioFormatMPEG4AAC,
            seconds: Double(seconds),
            amplitude: 0,
            framesPerPacket: isOpus ? 960 : 0
        )
        // OpusHead: version 1, two channels, no pre-skip, 48 kHz, no gain, mapping family 0.
        let opusHead = Data("OpusHead".utf8) + Data([1, 2, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0])
        return Track(
            number: number,
            isVideo: false,
            codecID: codecID,
            codecPrivate: isOpus ? opusHead : try audioSpecificConfig(fromCookie: encoded.cookie),
            packets: encoded.packets
        )
    }
}
