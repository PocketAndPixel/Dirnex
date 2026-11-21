import Foundation

/// What the sound rule needs to know of a track (PLAN.md §M42 ▸ Sound tracks): Matroska's tracks,
/// AVI's streams, and the app's description of what AVFoundation offers.
public protocol MediaSoundCandidate {
    /// An ISO 639 code or a BCP 47 tag, or `nil` where the file names none, as an AVI never does.
    var soundLanguage: String? { get }
    /// Whether the file marks it as the one to play.
    var isDefault: Bool { get }
    /// Whether it is a commentary or a description of the picture for the blind, which is never the
    /// sound a language picks on its own (`MediaSoundChoice.namesCommentary`).
    var isSecondarySound: Bool { get }
}

/// Which sound plays when a file goes up (PLAN.md §M42 ▸ Sound tracks): **the first in the app's
/// language**, so a film opens in the language Dirnex itself speaks, and the file's own choice
/// otherwise.
///
/// Within the language the file's default wins over the first, so a Russian Dirnex plays Oleg's film's
/// default dub (track 2) rather than the other five Russian tracks. A commentary in the language is
/// passed over, since it is not the film: an English Dirnex finds two English tracks in that film, the
/// DTS original, which nothing here decodes, and "AC3 2.0 Commentary", and plays the file's default,
/// the Russian dub. With no track in the language, the default plays if it decodes, else the first that
/// does, which is the rule Slice 4 shipped.
public enum MediaSoundChoice {
    /// The one of `sounds` that plays first. `sounds` are the ones this Mac decodes, in the file's
    /// order; `language` is the app's, or `nil`, which leaves the file's own choice.
    public static func preferred<Sound: MediaSoundCandidate>(
        _ sounds: [Sound],
        language: String?
    ) -> Sound? {
        let spoken = sounds.filter {
            !$0.isSecondarySound && MediaLanguage.matches($0.soundLanguage, language)
        }
        if let choice = spoken.first(where: \.isDefault) ?? spoken.first { return choice }
        return sounds.first(where: \.isDefault) ?? sounds.first
    }

    /// Whether a track's name says it is a commentary. Most files say it no other way: Matroska's
    /// `FlagCommentary` is a late addition to the format, and no file on Oleg's Mac sets it, the film's
    /// "AC3 2.0 Commentary" among them. English alone, as release groups write it.
    public static func namesCommentary(_ name: String?) -> Bool {
        name?.range(of: "commentary", options: .caseInsensitive) != nil
    }
}
