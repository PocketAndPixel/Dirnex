import AppKit
import DirnexCore

/// The questions and reports a save raises in the compare window (PLAN.md §M33 Slice 3), and those
/// a file changing under it raises (Slice 5), each a sheet on the window. The merge window's save
/// asks and reports the first two the same way (PLAN.md §M34 Slice 3).
extension CompareWindowController {
    /// The file changed since it was read: write over it or leave it. `true` to save anyway.
    static func askToSaveAnyway(_ name: String, over window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.changedSinceReadTitle(name)
        alert.informativeText = String(
            localized: "Saving now replaces those changes with the lines shown here.",
            comment: "Compare window save prompt body, when the file changed since it was read."
        )
        alert.addButton(withTitle: String(
            localized: "Save Anyway",
            comment: "Button that saves a file from the compare window over changes made since it was read."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        let response = await alert.sheetAnswer(over: window, whenUnasked: .alertSecondButtonReturn)
        return response == .alertFirstButtonReturn
    }

    /// The file changed since it was read, while copies made on it here are not yet saved: read it
    /// again, dropping them, or keep them. `true` to read it again. Kept, they are what ⌘S writes,
    /// and ⌘S asks first, as for any file changed since it was read.
    func askToReadAgain(_ name: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Self.changedSinceReadTitle(name)
        alert.informativeText = String(
            localized: """
            Reading it again shows it as it is now, without the changes copied into it here.
            """,
            comment: """
            Compare window prompt body, when a file with changes copied into it but not saved has \
            changed on disk, for instance saved in a text editor.
            """
        )
        alert.addButton(withTitle: String(
            localized: "Read Again",
            comment: "Button that shows a file as it now is on disk, dropping the compare window's unsaved copies."
        ))
        alert.addButton(withTitle: String(
            localized: "Keep Copied Changes",
            comment: "Button that keeps the compare window's unsaved copies over a file that changed on disk."
        ))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        let response = await alert.sheetAnswer(over: window, whenUnasked: .alertSecondButtonReturn)
        return response == .alertFirstButtonReturn
    }

    /// Edit was pressed on a side with copies not yet saved: save them first, since the editor
    /// opens the file and not this window's lines. `true` to save and edit.
    func askToSaveBeforeEditing(_ name: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Save the changes to “\(name)” before editing it?",
            comment: """
            Compare window prompt title, before opening a file with unsaved copies in a text \
            editor; %@ is a file name.
            """
        )
        alert.informativeText = String(
            localized: """
            The editor opens the file as it is saved, so the changes copied into it here are \
            saved first.
            """,
            comment: "Compare window prompt body, before opening a file with unsaved copies in a text editor."
        )
        alert.addButton(withTitle: String(
            localized: "Save and Edit",
            comment: "Button that saves a file from the compare window, then opens it in a text editor."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        let response = await alert.sheetAnswer(over: window, whenUnasked: .alertSecondButtonReturn)
        return response == .alertFirstButtonReturn
    }

    /// A file changed and can no longer be compared as text. The window goes on showing it as it
    /// was read.
    func reportUnreadableAgain(_ failure: CompareReadFailure) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = CompareOpener.failureTitle
        alert.informativeText = CompareOpener.failureDetail(failure)
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        _ = await alert.sheetAnswer(over: window, whenUnasked: .alertFirstButtonReturn)
    }

    /// "The file has changed since this window read it", which a save asks over and a read again
    /// asks over.
    private static func changedSinceReadTitle(_ name: String) -> String {
        String(
            localized: "“\(name)” has changed since this window read it.",
            comment: """
            Compare window prompt title, when a file changed on disk since the window read it; %@ \
            is a file name.
            """
        )
    }

    /// A save that did not happen, and why.
    static func reportSaveFailure(_ name: String, detail: String, over window: NSWindow?) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t save “\(name)”",
            comment: "Compare window save failure title; %@ is a file name."
        )
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        _ = await alert.sheetAnswer(over: window, whenUnasked: .alertFirstButtonReturn)
    }

    /// Why a line cannot be saved: a character its file's encoding has no bytes for. `line` counts
    /// from 0, and the sentence from 1, as the line numbers in the panes do.
    static func unencodableDetail(
        _ character: Character,
        line: Int,
        in encoding: String.Encoding
    ) -> String {
        let encodingName = String.localizedName(of: encoding)
        return String(
            localized: """
            “\(String(character))” on line \(line + 1) can’t be written in \(encodingName), the \
            file’s encoding. Dirnex saves a file in the encoding it was read in.
            """,
            comment: """
            Compare window save failure detail; %1$@ is a character, %2$lld a line number, %3$@ an \
            encoding name such as “Western (Windows Latin 1)”.
            """
        )
    }

    /// Save, Don't Save or Cancel, before the window closes or the app quits with edits a save
    /// could keep. Save is the default, ⎋ cancels and ⌘D is Don't Save, as in any Mac app.
    func askAboutUnsavedSides() async -> CloseAnswer {
        let names = unsavedSides.map { source(on: $0).name }
        let alert = NSAlert()
        alert.messageText = names.count == 1
            ? String(
                localized: "Do you want to save the changes you made to “\(names[0])”?",
                comment: "Compare window close prompt title; %@ is a file name."
            )
            : String(
                localized: "Do you want to save the changes you made to “\(names[0])” and “\(names[1])”?",
                comment: "Compare window close prompt title for both files; each %@ is a file name."
            )
        alert.informativeText = String(
            localized: "Your changes will be lost if you don’t save them.",
            comment: "Compare window close prompt body."
        )
        alert.addButton(
            withTitle: String(localized: "Save", comment: "Button that saves the edited files.")
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        let discard = alert.addButton(withTitle: String(
            localized: "Don’t Save",
            comment: "Button that closes the compare window and drops the copies made in it."
        ))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        switch await alert.sheetAnswer(over: window, whenUnasked: .alertSecondButtonReturn) {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}
