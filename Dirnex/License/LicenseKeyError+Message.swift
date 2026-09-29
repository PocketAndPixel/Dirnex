import DirnexCore
import Foundation

extension LicenseKeyError {
    /// What to tell someone whose key was refused. The core names the reason; the words live here,
    /// where they can be translated (docs/NOTES.md ▸ Localization, "a presentation decision in the
    /// core is a string that can never be translated").
    ///
    /// Each one says what to do next. Most refusals are a key copied short or with a stray
    /// character, so the usual advice is to copy it again, all of it.
    var message: String {
        switch self {
        case .empty:
            String(
                localized: "Paste a license key first.",
                comment: "License key refused: the field was empty."
            )
        case .tooLong:
            String(
                localized: "That’s far longer than a license key. Paste just the key from the email.",
                comment: "License key refused: the pasted text is much longer than any key."
            )
        case .wrongPrefix:
            String(
                localized: "That isn’t a Dirnex license key. A key starts with “dnx1.”",
                comment: "License key refused: not a Dirnex key. dnx1. is the literal start of every key."
            )
        case .unsupportedVersion:
            String(
                localized: "This license key needs a newer version of Dirnex. Check for updates, then try again.",
                comment: "License key refused: it is in a newer format than this version understands."
            )
        case .malformed:
            String(
                localized: "This license key is incomplete. Copy it again from the email, all of it.",
                comment: "License key refused: damaged or cut short while copying."
            )
        case .badSignature:
            String(
                localized: """
                This license key isn’t valid. Copy it again from the email, and if it still fails, \
                reply to that email.
                """,
                comment: "License key refused: the signature does not match (changed, or not a real key)."
            )
        case .invalidPayload:
            String(
                localized: "This license key can’t be read. Please reply to the email it came in.",
                comment: "License key refused: signed, but its contents are unreadable (a store bug)."
            )
        }
    }
}
