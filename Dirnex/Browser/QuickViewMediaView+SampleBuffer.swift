import AppKit
import DirnexCore

/// The header's readout for a file the core reads (PLAN.md §M42 ▸ Slices 4 and 5): the same play
/// state, place and facts as any movie, and a tooltip that names its sound tracks, which one plays, and
/// which this Mac cannot decode.
///
/// A film carries several sounds where an MP4 carries one, and the one that plays is chosen by a rule
/// (`MediaPlaybackPlan`): the default if it decodes, else the first that does. The film on this Mac
/// has four DTS tracks among nine, so a silent track left unnamed would read as a broken player.
extension QuickViewMediaView {
    func sampleBufferReadout(_ player: SampleBufferPlayer) -> QuickViewMediaReadout {
        let facts = summary?.facts ?? ""
        let sounds = Self.soundLines(
            player.preparation.sounds,
            playing: player.preparation.audio?.number
        )
        let lines = ([facts] + sounds).filter { !$0.isEmpty }
        return QuickViewMediaReadout(
            isPlaying: player.isPlaying,
            time: MediaTimecode.readout(at: player.currentSeconds, of: player.duration),
            facts: facts,
            detail: sounds.isEmpty ? nil : lines.joined(separator: "\n")
        )
    }

    /// One line per sound track, the playing one marked: "▶ Russian · AC-3 · 5.1", and
    /// "English · DTS · 5.1 — can’t play" for one nothing here decodes. Only worth saying when there is
    /// more than one, or when the one there is cannot play.
    static func soundLines(_ sounds: [SampleBufferPreparation.Sound], playing: UInt64?) -> [String] {
        guard sounds.count > 1 || sounds.contains(where: { !$0.isDecodable }) else { return [] }
        return sounds.map { sound in
            var parts = [sound.language.flatMap(languageName), sound.codec].compactMap(\.self)
            if let channels = sound.channels { parts.append(channelLayout(channels)) }
            if let name = sound.name, !name.isEmpty { parts.append(name) }
            let line = parts.joined(separator: " · ")
            if !sound.isDecodable {
                return String(
                    localized: "\(line) — can’t play",
                    comment: "Quick View tooltip: a sound track no decoder on this Mac plays; %@ names the track."
                )
            }
            return sound.number == playing ? "▶ \(line)" : line
        }
    }

    /// The language's name in the user's language, or `nil` for `und`, a file saying it does not know.
    /// Matroska gives ISO 639-2 codes (`rus`) or BCP 47 tags (`en-US`), and Foundation names both.
    static func languageName(_ code: String) -> String? {
        guard !code.isEmpty, code != "und" else { return nil }
        let language = code.split(separator: "-").first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: language) ?? code
    }

    /// "5.1" for six channels, as every film's box says it; "2.0" for stereo.
    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(channels).0"
        }
    }
}
