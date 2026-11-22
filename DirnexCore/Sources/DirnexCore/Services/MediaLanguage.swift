import Foundation

/// A sound track's language, set against the app's (PLAN.md §M42 ▸ Sound tracks).
///
/// Files spell a language three ways: ISO 639-2's bibliographic codes, which mkvmerge writes (`ger`,
/// `fre`, `chi`); its terminology codes and ISO 639-1 (`deu`, `rus`, `ru`), which the series on Oleg's
/// Mac carry beside each other; and BCP 47 tags (`en-US`, `pt-BR`). Foundation folds the last two to
/// one primary code and does not know the first: probed 2026-11-21, `Locale.LanguageCode("deu")` reads
/// `de` and `Locale.LanguageCode("ger")` has no ISO 639-1 code at all. So the twenty bibliographic
/// codes that differ from their terminology twins are mapped before Foundation is asked.
public enum MediaLanguage {
    /// The primary language of `code`, lower-cased and in ISO 639-1 where it has a code there: `ru` for
    /// `rus`, `ru` and `ru-RU`; `de` for `ger` and `deu`; `zh` for `chi` and `zh-Hans`. `nil` for a
    /// file saying it does not know (`und`), for several languages (`mul`), for none (`zxx`), and for
    /// nothing at all.
    public static func primary(_ code: String?) -> String? {
        guard let code,
              let first = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
        else { return nil }
        var subtag = first.lowercased()
        guard !unknown.contains(subtag) else { return nil }
        subtag = bibliographic[subtag] ?? subtag
        return Locale.LanguageCode(subtag).identifier(.alpha2) ?? subtag
    }

    /// Whether a track in `trackLanguage` speaks `language`, the app's (`en`, `pt-BR`, `zh-Hans`). Only
    /// the primary language counts: a Brazilian app takes a track marked `por`, and a Chinese one takes
    /// Mandarin and Cantonese alike, since a file marked `chi` says no more than that.
    public static func matches(_ trackLanguage: String?, _ language: String?) -> Bool {
        guard let track = primary(trackLanguage) else { return false }
        return track == primary(language)
    }

    /// The codes that name no language: undetermined, several, none, and uncoded.
    private static let unknown: Set<String> = ["und", "mul", "zxx", "mis"]

    /// ISO 639-2's bibliographic codes and the terminology codes Foundation knows them by.
    static let bibliographic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym"
    ]
}
