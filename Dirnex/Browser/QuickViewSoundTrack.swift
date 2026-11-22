import AppKit
import AVFoundation
import DirnexCore

/// One sound track of the movie on screen (PLAN.md §M42 ▸ Sound tracks), as the header's menu and the
/// facts' tooltip name it: "Russian · AC-3 · 5.1 · LostFilm".
///
/// The same for both players: the core's, where it describes a Matroska track or an AVI stream, and
/// AVFoundation's, where it describes one option of the file's group of alternative sounds.
struct QuickViewSoundTrack: Equatable, MediaSoundCandidate {
    /// What the player switches by: a Matroska track's number, an AVI stream's, or the place of an
    /// AVFoundation option in its group.
    let id: UInt64
    /// An ISO 639 code or a BCP 47 tag, or `nil` where the file names none, as an AVI never does.
    let language: String?
    let codec: String
    let channels: Int?
    let name: String?
    let isDecodable: Bool
    var isDefault = false
    var isSecondarySound = false

    var soundLanguage: String? { language }

    /// "Russian · AC-3 · 5.1 · LostFilm": its language, codec, channels and name, as far as known.
    var line: String {
        var parts = [language.flatMap { Self.languageName($0) }, codec].compactMap(\.self)
        if let channels { parts.append(Self.channelLayout(channels)) }
        if let name, !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " · ")
    }

    /// `line`, with "— can't play" after a track nothing here decodes, as the menu and the tooltip
    /// list it.
    var menuTitle: String {
        guard !isDecodable else { return line }
        return String(
            localized: "\(line) — can’t play",
            comment: "Quick View tooltip: a sound track no decoder on this Mac plays; %@ names the track."
        )
    }

    /// What the header's button says while it plays: its language, else its name, else its codec.
    /// Short, since the header has little room; the menu says the rest.
    var title: String {
        if let language = language.flatMap({ Self.languageName($0) }) { return language }
        if let name, !name.isEmpty { return name }
        return codec
    }

    /// One line per sound for the facts' tooltip, the playing one marked: "▶ Russian · AC-3 · 5.1", and
    /// "English · DTS · 5.1 — can’t play" for one nothing here decodes. Only worth saying when there is
    /// more than one, or when the one there is cannot play.
    static func tooltipLines(_ sounds: [Self], playing: UInt64?) -> [String] {
        guard sounds.count > 1 || sounds.contains(where: { !$0.isDecodable }) else { return [] }
        return sounds.map { sound in
            sound.isDecodable && sound.id == playing ? "▶ \(sound.line)" : sound.menuTitle
        }
    }

    /// The language's name in the user's language, or `nil` for `und`, a file saying it does not know.
    /// Files give ISO 639-2 codes, bibliographic (`ger`) or not (`rus`), and BCP 47 tags (`en-US`);
    /// `MediaLanguage` folds them to the code Foundation names. One Foundation cannot name is shown as
    /// the file spells it.
    ///
    /// Its first letter is a capital, since it heads the button, each menu line and each tooltip line:
    /// Foundation writes "русский" and "français" as they go mid-sentence, and the Russian header read
    /// "русский ⌄" (seen live 2026-11-21). Only the first letter, so "português do Brasil" keeps its
    /// lower-case "do".
    static func languageName(_ code: String, in locale: Locale = .current) -> String? {
        guard let primary = MediaLanguage.primary(code) else { return nil }
        guard let name = locale.localizedString(forLanguageCode: primary) else { return code }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
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

/// The sounds AVFoundation offers in a file as alternatives, one playing at a time, and the option
/// behind each (PLAN.md §M42 ▸ Sound tracks).
///
/// **Only a group of alternatives is a choice.** Probed 2026-11-21 over MP4s written with and without
/// an `AVAssetWriterInputGroup`: tracks sharing an alternate group come back as an audible
/// `AVMediaSelectionGroup`, one track enabled, and AVPlayer plays the one selected. Tracks in no group
/// are all enabled and AVPlayer plays them together, as QuickTime Player does, which is what a
/// recording with a microphone on a track of its own means. Those are left to play as the file says.
/// FFmpeg puts every sound of a file in one group, and so does everything built on it.
struct QuickViewAudibleOptions {
    let group: AVMediaSelectionGroup
    /// One per option, in the group's order, each `id` its place there.
    let sounds: [QuickViewSoundTrack]

    /// The option behind `id`, or `nil` for one the file does not have.
    func option(_ id: UInt64) -> AVMediaSelectionOption? {
        Int(exactly: id).flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
    }

    /// The place of `option` in the group.
    func id(of option: AVMediaSelectionOption?) -> UInt64? {
        option.flatMap { group.options.firstIndex(of: $0) }.map(UInt64.init)
    }

    /// `asset`'s alternatives, or `nil` for a file with fewer than two.
    @MainActor
    static func load(_ asset: AVURLAsset) async -> QuickViewAudibleOptions? {
        guard let group = try? await asset.loadMediaSelectionGroup(for: .audible),
              group.options.count > 1
        else { return nil }
        var sounds: [QuickViewSoundTrack] = []
        for (place, option) in group.options.enumerated() {
            let track = await track(of: option, in: asset)
            let name = track?.name
            sounds.append(QuickViewSoundTrack(
                id: UInt64(place),
                language: option.extendedLanguageTag ?? option.locale?.identifier,
                codec: option.mediaSubTypes.first.map {
                    MediaCodecName.name(for: FourCharCode(truncating: $0))
                } ?? "",
                channels: track?.channels,
                name: name,
                isDecodable: option.isPlayable,
                isDefault: option == group.defaultOption,
                isSecondarySound: option.hasMediaCharacteristic(.isAuxiliaryContent)
                    || option.hasMediaCharacteristic(.describesVideoForAccessibility)
                    || MediaSoundChoice.namesCommentary(name)
            ))
        }
        return QuickViewAudibleOptions(group: group, sounds: sounds)
    }

    /// What the option's track says that the option does not: its channels and its name. An option
    /// names no track in public, and its property list does (`MediaSelectionOptionsPersistentID`,
    /// probed 2026-11-21), so without that key the menu goes without the two.
    @MainActor
    private static func track(
        of option: AVMediaSelectionOption,
        in asset: AVURLAsset
    ) async -> (channels: Int?, name: String?)? {
        guard let properties = option.propertyList() as? [String: Any],
              let id = (properties["MediaSelectionOptionsPersistentID"] as? NSNumber)?.int32Value,
              let track = try? await asset.loadTrack(withTrackID: id),
              let (descriptions, metadata) = try? await track.load(.formatDescriptions, .metadata)
        else { return nil }
        let channels = descriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map(Int.init)
        let named = AVMetadataItem.metadataItems(
            from: metadata,
            filteredByIdentifier: .quickTimeUserDataTrackName
        )
        let name = try? await named.first?.load(.stringValue)
        return (channels, name)
    }
}
