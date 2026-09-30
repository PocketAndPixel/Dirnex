import Foundation

/// Why a vault could not be created, unlocked or locked.
///
/// The same named-vocabulary shape as `ChecksumError` and `EncryptedArchiveError`, for the same
/// reason: these sentences reach the screen through a *return value*, so a bare literal would
/// extract nothing and render English under a translated alert title.
///
/// `hdiutil`'s own stderr is **not** carried here. It is English, it names internal machinery
/// ("hdiutil: attach failed - Authentication error"), and a free-form `String` payload on an error
/// case is an untranslatable string with extra steps — the `VFSError.unsupported(String)` trap.
/// Classification is by **exit code plus the one distinguishing phrase**, and the sentence is ours.
public enum VaultError: Error, Sendable, Equatable {
    /// The passphrase did not unlock the vault. `hdiutil` reports this as `Authentication error`
    /// with exit 1 (probed).
    case incorrectPassphrase

    /// The user left the passphrase blank, or the two entries differed. A vault whose passphrase is
    /// the empty string is not protected, and one whose passphrase was mistyped can never be opened
    /// again — there is no recovery, which is why both are caught before anything is created.
    case emptyPassphrase
    case passphrasesDoNotMatch

    /// A vault already exists at that path. Refused rather than overwritten: replacing a vault
    /// destroys every byte inside it, irreversibly and with no Trash to recover from.
    case alreadyExists(name: String)

    /// The image file is missing, or is not a disk image at all.
    case imageUnreadable(name: String)

    /// The new name is not one a volume can have — empty, `.`/`..`, longer than
    /// ``VolumeName/maximumByteCount``, or carrying a control character. Caught before `diskutil` is
    /// run so the reason is a translated sentence rather than the tool's scraped English.
    case invalidVolumeName

    /// `hdiutil` failed for a reason Dirnex cannot name more precisely.
    case couldNotCreate
    case couldNotUnlock
    case couldNotLock

    /// `diskutil rename` refused. Unlike the three above this can only happen with the vault already
    /// unlocked, so it is never a passphrase problem.
    case couldNotRename

    /// The volume is in use, so it cannot be unmounted — a file open in another app, or a Terminal
    /// sitting inside it. `hdiutil` calls this "Resource busy".
    case volumeInUse(name: String)

    /// The stable translation key token — the case name, spelled once, never derived.
    public var key: String {
        switch self {
        case .incorrectPassphrase: return "incorrectPassphrase"
        case .emptyPassphrase: return "emptyPassphrase"
        case .passphrasesDoNotMatch: return "passphrasesDoNotMatch"
        case .alreadyExists: return "alreadyExists"
        case .imageUnreadable: return "imageUnreadable"
        case .invalidVolumeName: return "invalidVolumeName"
        case .couldNotCreate: return "couldNotCreate"
        case .couldNotUnlock: return "couldNotUnlock"
        case .couldNotLock: return "couldNotLock"
        case .couldNotRename: return "couldNotRename"
        case .volumeInUse: return "volumeInUse"
        }
    }

    /// Classifies a failed `hdiutil attach`.
    ///
    /// Exit code alone cannot do it — probed, both a wrong passphrase and a missing file exit `1` —
    /// so the one phrase that separates them is matched, narrowly and case-insensitively, exactly as
    /// `LibArchive.isIncorrectPassphrase` does for the same reason. The distinction matters because
    /// the two need opposite responses: retype it, or go and find the file.
    public static func fromAttachFailure(exitCode: Int32, stderr: String, name: String) -> VaultError {
        guard exitCode != 0 else { return .couldNotUnlock }
        let text = stderr.lowercased()
        if text.contains("authentication") { return .incorrectPassphrase }
        if text.contains("no such file") || text.contains("not recognized") {
            return .imageUnreadable(name: name)
        }
        return .couldNotUnlock
    }

    /// Classifies a failed `hdiutil detach`.
    ///
    /// **Exit 1 with "no such file" is success, not failure.** Probed: detaching an already-detached
    /// vault exits 1 and says so, and the user's intent — "this must not be mounted" — is already
    /// satisfied. Reporting an error there would make a second Lock, or a Lock after the user
    /// ejected the volume in Finder, look broken. `nil` means "treat as done", the same idempotence
    /// rule `ExtendedAttributeIO` applies to `ENOATTR`.
    public static func fromDetachFailure(exitCode: Int32, stderr: String, name: String) -> VaultError? {
        guard exitCode != 0 else { return nil }
        let text = stderr.lowercased()
        if text.contains("no such file") { return nil }
        if text.contains("busy") { return .volumeInUse(name: name) }
        return .couldNotLock
    }
}

public extension VaultError {
    /// The English sentence — the fallback shown when a translation is missing, and the only
    /// presentation a resource-free `swift test` ever sees.
    var sentence: String {
        let template = template
        guard !template.arguments.isEmpty else { return template.format }
        return String(format: template.format, arguments: template.arguments)
    }

    var englishFormat: String { template.format }
    var arguments: [String] { template.arguments }

    private var template: (format: String, arguments: [String]) {
        switch self {
        case .incorrectPassphrase:
            return ("That passphrase doesn’t unlock this vault.", [])
        case .emptyPassphrase:
            return ("Choose a passphrase. A vault without one isn’t protected.", [])
        case .passphrasesDoNotMatch:
            return ("The two passphrases don’t match.", [])
        case let .alreadyExists(name):
            return ("A vault named “%@” is already here.", [name])
        case let .imageUnreadable(name):
            return ("“%@” couldn’t be opened. It may have been moved or damaged.", [name])
        case .invalidVolumeName:
            // Deliberately not "255 bytes": the limit is in UTF-8 bytes, so the number that would
            // be true in English is wrong in Russian (127 characters, measured). "Shorter" is true
            // in every language.
            return (
                "That name can’t be used for a volume. Try a shorter one, without line breaks.",
                []
            )
        case .couldNotCreate:
            return ("The vault couldn’t be created.", [])
        case .couldNotUnlock:
            return ("The vault couldn’t be unlocked.", [])
        case .couldNotLock:
            return ("The vault couldn’t be locked.", [])
        case .couldNotRename:
            return ("The vault couldn’t be renamed.", [])
        case let .volumeInUse(name):
            return (
                "“%@” is still in use, so it couldn’t be locked. Close anything open inside it.",
                [name]
            )
        }
    }

    /// Every reason, with placeholder arguments where a case takes them — the coverage test's input.
    static var allCases: [VaultError] {
        [
            .incorrectPassphrase,
            .emptyPassphrase,
            .passphrasesDoNotMatch,
            .alreadyExists(name: ""),
            .imageUnreadable(name: ""),
            .invalidVolumeName,
            .couldNotCreate,
            .couldNotUnlock,
            .couldNotLock,
            .couldNotRename,
            .volumeInUse(name: "")
        ]
    }
}
