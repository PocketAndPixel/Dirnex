import AppKit
import DirnexCore

/// Asking for the passphrase that opens something (PLAN.md §M19 Slice 2).
///
/// One field, never two. The confirm field on the *pack* sheet exists because a mistyped passphrase
/// there is unrecoverable — it is written into an archive nobody can ever open again. Here the
/// passphrase is being checked against something that already exists, so a typo costs one refusal
/// and a retry, and a second field would only be a second thing to type.
///
/// The field is an `NSSecureTextField` and the value leaves as an ``ArchivePassphrase``: the caller
/// never sees a `String`, so there is no `String` for anybody to log, journal or interpolate later.
/// The field's own contents are AppKit's and are not ours to wipe — `ArchivePassphrase`'s doc
/// comment is precise about that being a shortening rather than an ending, and this is where that
/// limit actually lives.
enum PassphrasePrompt {
    /// Raise the prompt over `window`, calling `completion` with the passphrase, or with `nil` when
    /// the user canceled.
    ///
    /// `retrying` says a previous attempt was refused, which changes the message rather than adding
    /// a second alert on top: the first thing the user needs to know is that this one was wrong, and
    /// the second is that they can try again — which is the field already in front of them.
    @MainActor
    static func ask(
        forItemNamed name: String,
        retrying: Bool = false,
        over window: NSWindow?,
        completion: @escaping (ArchivePassphrase?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = retrying
            ? String(
                localized: "That passphrase didn’t open “\(name)”",
                comment: """
                Title of the passphrase prompt after a refused attempt; %@ is the archive's name.
                """
            )
            : String(
                localized: "“\(name)” is encrypted",
                comment: "Title of the passphrase prompt; %@ is the archive's name."
            )
        alert.informativeText = String(
            localized: "Enter its passphrase to open it.",
            comment: "Body of the passphrase prompt."
        )
        alert.addButton(withTitle: String(
            localized: "Open",
            comment: "Button that submits a passphrase to open an encrypted archive."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        // `NSAlert` binds Escape by matching the byte string "Cancel", so a translated button gets
        // no key equivalent at all (docs/NOTES.md). The response is the vocabulary, not the title.
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.keepToOneLine()
        field.placeholderString = String(
            localized: "Passphrase",
            comment: "Placeholder in the passphrase prompt's field."
        )
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(ArchivePassphrase(field.stringValue))
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
