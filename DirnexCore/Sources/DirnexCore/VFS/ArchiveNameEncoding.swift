import Foundation

/// The code page an archive's entry names are stored in, when they are not UTF-8 — the one fact
/// about such an archive that nothing on this machine can work out for itself.
///
/// A zip written before UTF-8 was usual stores names in an OEM code page with general-purpose bit 11
/// **clear**, and the file records nothing about which one. So `Панорама.txt` arrives as the CP866
/// bytes `8f a0 ad ae e0 a0 ac a0`, which are not valid UTF-8: ``SubprocessText`` keeps the listing
/// readable by replacing them, at the price of a row nobody can name, and this is what turns them
/// back into the name somebody typed.
///
/// **The user picks, and no code guesses.** Measured against the CP866 fixture in
/// `ArchiveNonASCIINameTests`, every candidate here is a token libarchive accepts, and a *wrong* one
/// fails in whichever of two ways is least useful — CP1251 reads that name as `Џ ­®а ¬ .txt` and
/// CP437 as `Åá¡«αá¼á.txt`, both perfectly well-formed, while CP1252 and Shift-JIS answer NULL
/// because a byte is unmapped there. Nothing distinguishes the right answer from the plausible ones
/// except somebody who can read the language, which is why this is offered as a choice over a
/// preview rather than inferred from the bytes.
///
/// This is a *reading*, and nothing is written until the user acts on it — so a wrong pick costs a
/// second pick. What it unlocks is the whole gesture set: once a name decodes it is an ordinary
/// Swift `String`, legal as an APFS file name, so extraction, F5, F8 and the rewrite all work with
/// no further special-casing. (APFS refuses a non-UTF-8 name outright — `EILSEQ`, measured — which
/// is why declaring the code page is the *only* route to those gestures, not merely the tidiest.)
public enum ArchiveNameEncoding: String, Sendable, CaseIterable, Identifiable, Equatable {
    // DOS / OEM code pages — what the zip format itself grew up on.
    case cp437, cp850, cp852, cp866
    // Windows ANSI code pages.
    case cp1250, cp1251, cp1252, cp1253, cp1254, cp1255, cp1256, cp1257
    // East Asian.
    case cp932, cp936, cp949, cp950
    // Everything else that turns up in the wild.
    case koi8r, macRoman, macCyrillic

    public var id: String { rawValue }

    /// The token handed to libarchive as `hdrcharset=…`.
    ///
    /// Spelled out rather than derived from ``rawValue`` because the two vocabularies do not agree:
    /// libarchive wants `KOI8-R` and `MacCyrillic`, which are not case transformations of any Swift
    /// case name. Every value here is checked against the real libarchive in
    /// `ArchiveNameEncodingTests`, with a deliberately bogus token as the negative control — a typo
    /// would otherwise surface as an archive that cannot be opened.
    public var hdrcharset: String {
        switch self {
        case .cp437: "CP437"
        case .cp850: "CP850"
        case .cp852: "CP852"
        case .cp866: "CP866"
        case .cp1250: "CP1250"
        case .cp1251: "CP1251"
        case .cp1252: "CP1252"
        case .cp1253: "CP1253"
        case .cp1254: "CP1254"
        case .cp1255: "CP1255"
        case .cp1256: "CP1256"
        case .cp1257: "CP1257"
        case .cp932: "CP932"
        case .cp936: "CP936"
        case .cp949: "CP949"
        case .cp950: "CP950"
        case .koi8r: "KOI8-R"
        case .macRoman: "MacRoman"
        case .macCyrillic: "MacCyrillic"
        }
    }

    /// The catalog key the app localizes this through. Stable, never displayed.
    public var localizationKey: String { "archive.nameEncoding.\(rawValue)" }

    /// The English name, and the fallback a resource-free `swift test` sees.
    ///
    /// It names the **script** first and the code page second, because that is the half the person
    /// choosing can recognize: somebody looking at mojibake knows the archive came from a Russian
    /// colleague, and does not know whether the tool that wrote it used CP866 or CP1251. The number
    /// is kept because it is what every other archiver shows, so a user who does know can go
    /// straight to it.
    public var englishName: String {
        switch self {
        case .cp437: "Western European (DOS, CP437)"
        case .cp850: "Western European (DOS, CP850)"
        case .cp852: "Central European (DOS, CP852)"
        case .cp866: "Cyrillic (DOS, CP866)"
        case .cp1250: "Central European (Windows, CP1250)"
        case .cp1251: "Cyrillic (Windows, CP1251)"
        case .cp1252: "Western European (Windows, CP1252)"
        case .cp1253: "Greek (Windows, CP1253)"
        case .cp1254: "Turkish (Windows, CP1254)"
        case .cp1255: "Hebrew (Windows, CP1255)"
        case .cp1256: "Arabic (Windows, CP1256)"
        case .cp1257: "Baltic (Windows, CP1257)"
        case .cp932: "Japanese (Shift JIS, CP932)"
        case .cp936: "Simplified Chinese (GBK, CP936)"
        case .cp949: "Korean (CP949)"
        case .cp950: "Traditional Chinese (Big5, CP950)"
        case .koi8r: "Cyrillic (KOI8-R)"
        case .macRoman: "Western European (Mac OS Roman)"
        case .macCyrillic: "Cyrillic (Mac OS)"
        }
    }
}
