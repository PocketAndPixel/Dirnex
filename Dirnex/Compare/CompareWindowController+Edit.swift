import AppKit
import DirnexCore

/// Edit Left and Edit Right (PLAN.md §M33 Slice 5): one side opened in the user's own editor, the
/// way F4 opens a file. The pencil at the end of each pane's name, or F4 for the pane holding the
/// keyboard.
///
/// The window copies lines and never types (M11's call), so an edit by hand goes to the editor the
/// user chose, and the window's watch (`+Watch`) shows its save. The editor is handed what F4 would
/// hand it: a local file itself, and for a server file or an archive member the copy this window
/// read, which the browser window's `EditedFileRegistry` then watches, so the editor's save is
/// offered back exactly as F4's is, with the same check and the same question. Copies not yet saved
/// on that side are saved first, since the editor opens the file and not this window's lines.
extension CompareWindowController {
    /// Whether the file on `side` can be opened in the editor: a window that takes copies, over a
    /// file it could save. A member of an archive inside another archive has nowhere to go back to,
    /// and F4 refuses it as well.
    func canEdit(_ side: ComparisonPaneText.Side) -> Bool {
        allowsCopies && source(on: side).target != nil
    }

    /// The pencil buttons as the sides stand, each naming the editor it would open.
    func refreshEditControls() {
        let editor = ExternalTextEditorLauncher.preferredEditor()?.displayName
        for (side, pane) in panes {
            pane.editButton.isEnabled = canEdit(side)
            pane.editButton.toolTip = "\(ComparePaneView.editTitle(side, in: editor)) (F4)"
        }
    }

    /// Edit Left, Edit Right or F4: open the file on `side` in the editor.
    func editFile(on side: ComparisonPaneText.Side) {
        guard canEdit(side), !isSaving else { return NSSound.beep() }
        let id = source(on: side).id
        Task { await editFile(id) }
    }

    /// Open the file `id` names in the editor, saving its copies first.
    func editFile(_ id: UUID) async {
        guard let side = side(ofFile: id) else { return }
        if unsavedSides.contains(side) {
            guard await askToSaveBeforeEditing(source(on: side).name) else { return }
            guard await saveOnly(id) else { return }
        }
        // Swap Sides cannot run while the question is up, but the save can have moved the target.
        guard let side = self.side(ofFile: id), let path = source(on: side).target?.path else {
            return
        }
        let source = source(on: side)
        let url = URL(fileURLWithPath: path)
        if let destination = source.writeBack {
            saving.watchCopy(
                EditedFile(destination: destination, temporaryURL: url, name: source.name)
            )
        }
        saving.openInEditor(url) { [weak self] editor, error in
            self?.reportEditorFailure(editor: editor, error: error, name: source.name)
        }
    }

    /// What F4 says when no editor opened the file, here on the compare window.
    private func reportEditorFailure(editor: ApplicationRef?, error: (any Error)?, name: String) {
        guard editor == nil || error != nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let error {
            alert.messageText = String(
                localized: "Couldn’t open “\(name)”",
                comment: "Failure title; %@ is the name of the item that couldn’t be opened."
            )
            alert.informativeText = VFSErrorText.sentence(for: error)
        } else {
            alert.messageText = String(
                localized: "No text editor found",
                comment: "F4 failure when no plain-text editor is registered."
            )
            alert.informativeText = String(
                localized: "macOS reports no application for plain text. Choose one in Settings ▸ Operations.",
                comment: "F4 failure detail pointing to the settings."
            )
        }
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        alert.offerFullDiskAccessSettings()
        Task { _ = await alert.sheetAnswer(over: window, whenUnasked: .alertFirstButtonReturn) }
    }
}
