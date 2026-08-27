import Foundation

/// Why an encrypted archive could not be written or read.
///
/// A named vocabulary rather than a `String` payload, for the reason `ChecksumError` and
/// `VFSUnsupportedReason` are: these sentences reach the screen through a *return value*, not an
/// assignment, so a bare literal here is invisible to Xcode's extractor and to every bare-literal
/// sweep alike — it would render English under a translated alert title at the exact moment
/// something failed (docs/NOTES.md, "Localization").
///
/// **libarchive's own error strings are deliberately not carried in here.** They are English, they
/// name internal state ("Incorrect passphrase: Unknown error: -1" is the literal text for a wrong
/// passphrase), and a `String` payload on an error case is an untranslatable string with extra
/// steps — the trap `VFSError.unsupported(String)` had to be dug out of. The classification below
/// is made from libarchive's *return code* plus a narrow match on the one message that has no
/// other signal, and the sentence the user reads is ours.
///
/// Ordinary I/O failures are not here either: a missing file or a denied read throws `VFSError`
/// through `fromErrno`, as `ByteComparator` and `ChecksumEngine` already do, so the app's existing
/// error text handles them unchanged.
public enum EncryptedArchiveError: Error, Sendable, Equatable {
    /// The passphrase did not decrypt the archive.
    ///
    /// For WinZip AES this is a real check, not a guess: the format stores a 2-byte password
    /// verifier and an HMAC-SHA1 authentication code, so libarchive can say "wrong passphrase"
    /// rather than handing back garbage. Worth stating because the legacy ZipCrypto cipher Dirnex
    /// refuses to write *cannot* reliably tell those apart, and a file manager that silently wrote
    /// out corrupt plaintext would be the worse failure.
    case incorrectPassphrase

    /// The archive holds encrypted entries and no passphrase was supplied. Not a failure in itself —
    /// it is what the extract path throws so the app knows to ask.
    case passphraseRequired

    /// The user asked to encrypt but left the passphrase blank. Refused rather than accepted,
    /// because an archive encrypted with the empty string reads as protected and is not.
    case emptyPassphrase

    /// The two passphrase fields did not match. Caught before a byte is written, since the whole
    /// cost of a mistyped passphrase is that the archive can never be opened again.
    case passphrasesDoNotMatch

    /// The archive is damaged, truncated, or not an archive at all.
    case archiveUnreadable

    /// The archive file could not be created or written — a full disk, a read-only destination, a
    /// path that vanished mid-write.
    case archiveNotWritable

    /// An entry's name is not valid UTF-8, so Dirnex will not guess at what it says.
    ///
    /// A zip stores names as bytes with no declared encoding, and the historical fallback is the
    /// creating machine's code page. Guessing produces a plausible wrong filename, which is worse
    /// than refusing: the file lands on disk under a name the user did not choose and cannot find.
    case entryNameNotUTF8(archive: String)

    /// A file being packed is a cloud placeholder (`SF_DATALESS`): its bytes are not on this disk,
    /// and reading them would make the provider materialize the whole file and block.
    ///
    /// Named rather than silently downloaded, following the split docs/NOTES.md draws: a file the
    /// user pointed at may be downloaded on request, but packing a *folder* is a tree sweep that
    /// crosses files nobody selected, so it stops and names the first one.
    case wouldDownloadPlaceholder(name: String)

    /// A file changed size while it was being packed, so what reached the archive is not what was
    /// on disk.
    ///
    /// Reported rather than absorbed. libarchive is told each entry's length before its bytes, and
    /// when fewer arrive it pads the remainder with NULs — so a file being written by another app
    /// while Dirnex packs it lands in the archive **silently truncated and zero-filled**, and the
    /// archive is perfectly valid. That is the quiet-direction failure this codebase spends its
    /// comments on; the whole pack fails instead.
    case sourceChangedDuringPacking(name: String)

    /// There was nothing to put in the archive.
    case nothingToArchive

    /// The stable translation key token — the case name, spelled once, never derived.
    public var key: String {
        switch self {
        case .incorrectPassphrase: return "incorrectPassphrase"
        case .passphraseRequired: return "passphraseRequired"
        case .emptyPassphrase: return "emptyPassphrase"
        case .passphrasesDoNotMatch: return "passphrasesDoNotMatch"
        case .archiveUnreadable: return "archiveUnreadable"
        case .archiveNotWritable: return "archiveNotWritable"
        case .entryNameNotUTF8: return "entryNameNotUTF8"
        case .wouldDownloadPlaceholder: return "wouldDownloadPlaceholder"
        case .sourceChangedDuringPacking: return "sourceChangedDuringPacking"
        case .nothingToArchive: return "nothingToArchive"
        }
    }
}

public extension EncryptedArchiveError {
    /// The English sentence — the fallback the app shows when a translation is missing, and the only
    /// presentation a resource-free `swift test` ever sees.
    var sentence: String {
        let template = template
        guard !template.arguments.isEmpty else { return template.format }
        return String(format: template.format, arguments: template.arguments)
    }

    /// The English format, with `%@` placeholders in ``arguments`` order.
    var englishFormat: String { template.format }

    /// The values to splice into ``englishFormat`` — or into its translation, which may reorder them
    /// with positional specifiers (`%1$@`).
    var arguments: [String] { template.arguments }

    /// Format and arguments together, so the two can never drift apart.
    private var template: (format: String, arguments: [String]) {
        switch self {
        case .incorrectPassphrase:
            return ("That passphrase doesn’t open this archive.", [])
        case .passphraseRequired:
            return ("This archive is encrypted. Enter its passphrase to open it.", [])
        case .emptyPassphrase:
            return (
                "Choose a passphrase. An archive encrypted with a blank one isn’t protected.",
                []
            )
        case .passphrasesDoNotMatch:
            return ("The two passphrases don’t match.", [])
        case .archiveUnreadable:
            return ("This archive couldn’t be read. It may be damaged or incomplete.", [])
        case .archiveNotWritable:
            return ("The archive couldn’t be written.", [])
        case let .entryNameNotUTF8(archive):
            return (
                "“%@” contains a file whose name isn’t readable text, so it wasn’t extracted.",
                [archive]
            )
        case let .wouldDownloadPlaceholder(name):
            return (
                "“%@” isn’t downloaded yet. Adding it to an archive would download it first.",
                [name]
            )
        case let .sourceChangedDuringPacking(name):
            return ("“%@” changed while it was being added, so the archive wasn’t created.", [name])
        case .nothingToArchive:
            return ("There’s nothing to put in the archive.", [])
        }
    }

    /// Every reason, with placeholder arguments where a case takes them — the coverage test's input.
    /// `CaseIterable` cannot be synthesized for an enum with associated values, and the ``key`` does
    /// not depend on them, so a representative value per case is exactly enough.
    static var allCases: [EncryptedArchiveError] {
        [
            .incorrectPassphrase,
            .passphraseRequired,
            .emptyPassphrase,
            .passphrasesDoNotMatch,
            .archiveUnreadable,
            .archiveNotWritable,
            .entryNameNotUTF8(archive: ""),
            .wouldDownloadPlaceholder(name: ""),
            .sourceChangedDuringPacking(name: ""),
            .nothingToArchive
        ]
    }
}
