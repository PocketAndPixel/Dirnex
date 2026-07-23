import AppKit
import DirnexCore

/// F4 "Edit" and ⇧F4 "Edit File…" (PLAN.md §M11) — the last unbound key on the Total Commander
/// row, bound by *handing the file over* rather than by growing a text editor. A real editor is
/// encoding detection, line-ending preservation, a binary gate, undo grouping and find/replace,
/// and every Mac already has one the user has already chosen; F4 opens the file in it, exactly
/// the way ⌥F3 hands two files to FileMerge.
///
/// Which editor, and what "Automatic" means, is the pure tested `ExternalTextEditor`; this is the
/// AppKit shell — which file, whether there is one at all, and what to tell the user.
extension PanelViewController {
    // MARK: - Menu / palette actions (dispatched to the focused pane via the responder chain)

    /// F4 — edit the file under the cursor, no dialog.
    ///
    /// **Cursor item only, marks ignored**: this is "edit the thing I'm pointing at", and a dozen
    /// editor windows is not what a marked set means. A folder under the cursor is declined the way
    /// ⌥F3 declines one; but with *nothing* to point at — the `..` row, or an empty directory — F4
    /// falls through to ⇧F4's dialog rather than doing nothing, which is where Total Commander's
    /// two keys usefully converge.
    @objc func editCursorFile(_ sender: Any?) {
        guard let entry = cursorEntryToEdit() else {
            if isCursorOnNothing { promptForFileToEdit() }
            return
        }
        guard entry.path.backend == .local else {
            // An archive member or a remote file would edit an extracted temp copy whose saves go
            // nowhere. Said out loud rather than silently declined: a no-op that looks like it
            // worked is the expensive kind of wrong.
            showTransientStatus(
                String(
                    localized: "Only files on this Mac can be edited — copy it out first (F5).",
                    comment: "Status when F4 is pressed on an archive member or remote file."
                )
            )
            return
        }
        edit(entry)
    }

    /// ⇧F4 — name the file first. Prefilled with the cursor's name and selected, so Enter is "edit
    /// this one" and typing over it is "make a new one".
    @objc func editNewFile(_ sender: Any?) {
        promptForFileToEdit()
    }

    /// Validate both Edit items, naming the editor that would actually open — the same reason
    /// Compare By Contents retitles itself: "Edit" gives no hint what is about to launch, and with
    /// Automatic the user never chose it. The palette keeps the generic catalog title, which is
    /// what its fuzzy search matches against.
    func validateEditItem(_ menuItem: NSMenuItem) -> Bool? {
        let editor = ExternalTextEditorLauncher.preferredEditor()
        switch menuItem.action {
        case #selector(editCursorFile(_:)):
            menuItem.title = editor.map { String(
                localized: "Edit with \($0.displayName)",
                comment: "F4 menu title naming the chosen text editor; %@ is the app name."
            ) } ?? String(
                localized: "Edit",
                comment: "F4 menu title when no specific editor is chosen."
            )
            // Enabled exactly where the key does something, so "inert" is a *greyed* item rather
            // than a keystroke that vanishes: a local file to open, or nothing under the cursor at
            // all, where F4 becomes the ⇧F4 dialog. A folder or a non-local file greys out.
            guard editor != nil else { return false }
            if let entry = cursorEntryToEdit() { return entry.path.backend == .local }
            return isCursorOnNothing && canCreateFileHere
        case #selector(editNewFile(_:)):
            menuItem.title = editor.map { String(
                localized: "Edit File with \($0.displayName)…",
                comment: "⇧F4 menu title naming the chosen text editor; %@ is the app name."
            ) } ?? String(
                localized: "Edit File…",
                comment: "⇧F4 menu title when no specific editor is chosen."
            )
            return editor != nil && canCreateFileHere
        default:
            return nil
        }
    }

    /// Whether ⇧F4 can create into this pane. Gated on a **real directory** (`writeDirectory`) and
    /// not on `.write` alone: the merged Trash carries `.write` so its `deleteStrategy` resolves to
    /// `.permanent`, and that capability alone already lit up New Folder and Paste in a Trash tab
    /// (docs/NOTES.md). This is the same guard `promptForNewFolder` uses, for the same reason.
    private var canCreateFileHere: Bool {
        backend.capabilities(for: panel.path).contains(.write) && writeDirectory != nil
    }

    /// The entry F4 would act on: the cursor's, never the marked set, never the `..` row, and
    /// never a directory. `nil` means "nothing editable is being pointed at".
    private func cursorEntryToEdit() -> FileEntry? {
        guard !cursorOnParentRow, let entry = panel.currentEntry, entry.kind == .file else {
            return nil
        }
        return entry
    }

    /// Nothing at all is being pointed at — the `..` row, or an empty directory. Distinct from
    /// "something that isn't editable", which is a folder and stays inert: this is the case where
    /// F4 has no file to act on and so becomes ⇧F4's dialog.
    private var isCursorOnNothing: Bool {
        cursorOnParentRow || panel.currentEntry == nil
    }

    // MARK: - Opening

    /// Open a local file in the user's editor, fetching its bytes first when it has none.
    ///
    /// An evicted iCloud or streaming-Drive file is `SF_DATALESS`: it has its real name and its
    /// real size and no bytes, so handing the path to an editor doesn't fail — it blocks the editor
    /// while the provider materializes it (measured 1.1 s for 200 KB), with nothing anywhere saying
    /// why. The listing already carries `isDataless`, so the existing download prompt wraps the open
    /// exactly as it does for Enter.
    private func edit(_ entry: FileEntry) {
        CloudDownloadPrompt.materialize(entry, using: backend, over: view.window) { [weak self] in
            self?.openInEditor(entry.path)
        }
    }

    /// Hand a local path to the editor and say so. The launch is asynchronous and a cold editor
    /// takes seconds to draw its first window, so without this line the app looks like it swallowed
    /// the keystroke.
    private func openInEditor(_ path: VFSPath) {
        showTransientStatus(String(
            localized: "Opening \(path.lastComponent)…",
            comment: "In-progress status while opening a file; %@ is the file name."
        ))
        ExternalTextEditorLauncher.edit(path.localURL) { [weak self] editor, error in
            guard let self else { return }
            guard let editor else {
                clearTransientStatus()
                presentOperationFailure(
                    message: String(
                        localized: "No text editor found",
                        comment: "F4 failure when no plain-text editor is registered."
                    ),
                    detail: String(
                        localized: "macOS reports no application for plain text. Choose one in Settings ▸ Operations.",
                        comment: "F4 failure detail pointing to the settings."
                    )
                )
                return
            }
            guard let error else {
                showTransientStatus(
                    String(
                        localized: "Opening in \(editor.displayName)…",
                        comment: "In-progress status while opening a file in the editor; %@ is the app name."
                    )
                )
                return
            }
            clearTransientStatus()
            presentOperationFailure(
                message: String(
                    localized: "Couldn’t open “\(path.lastComponent)”",
                    comment: "F4 failure title; %@ is the file name."
                ),
                detail: describe(error)
            )
        }
    }

    // MARK: - ⇧F4: name it first

    /// The name dialog, shaped like New Folder's: an `NSAlert` with an accessory field, `/` refused
    /// with a real message, then `refreshCurrentDirectory(selecting:)` so a newly created file lands
    /// under the cursor.
    private func promptForFileToEdit() {
        guard let target = writeDirectory, canCreateFileHere else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Edit File",
            comment: "Title of the ⇧F4 edit/create-file dialog."
        )
        // The folder isn't named here: the path bar above the dialog already says which one this
        // is, and the field below is prefilled out of it.
        alert.informativeText = String(
            localized: "Open a file, or type a new name to create one.",
            comment: "Body of the ⇧F4 edit/create-file dialog."
        )
        alert.addButton(
            withTitle: String(
                localized: "Edit",
                comment: "Confirm button of the ⇧F4 edit/create-file dialog."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = prefilledName()
        field.placeholderString = String(
            localized: "File name",
            comment: "Placeholder in the ⇧F4 file-name field."
        )
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.editFile(named: name, in: target)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            // Selected, not just prefilled: Enter edits the name that's already there, and the
            // first keystroke replaces it outright to make a new one.
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// What the name field starts out holding — always something, and always selected, so the
    /// field is a *starting point to type over* rather than a blank the user has to fill from
    /// nothing. The cursor's own name whatever it is (a folder's included: ⇧F4 beside a folder is
    /// usually "something like that, but a file"), and where there is no cursor at all — the `..`
    /// row, an empty directory — the pane's own folder name.
    private func prefilledName() -> String {
        guard !cursorOnParentRow, let entry = panel.currentEntry else {
            return panel.path.lastComponent
        }
        return entry.name
    }

    /// Open `name` in `directory`, creating it first when nothing is there yet.
    ///
    /// The create is deliberately **not** undoable, unlike New Folder's. The file is handed to an
    /// external editor in the same breath, so by the time ⌘Z could be reached another app owns it —
    /// and a folder, which is what New Folder leaves behind, just sits there inert.
    private func editFile(named name: String, in directory: VFSPath) {
        guard !name.isEmpty else { return } // an empty name is a silent cancel
        guard !name.contains("/") else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t create the file",
                    comment: "Create-file failure title for an invalid name."
                ),
                detail: String(
                    localized: "File names can’t contain the “/” character.",
                    comment: "Create-file failure detail: slash in name."
                )
            )
            return
        }

        let target = directory.appending(name)
        let backend = backend
        Task {
            // One `stat` decides the branch: an existing name means *open that file*, which is why
            // `createFile` is `O_EXCL` underneath — a file appearing between this read and the
            // create is reported, never truncated.
            let existing = await Task.detached(priority: .userInitiated) {
                try? backend.stat(at: target)
            }.value
            if let existing {
                guard existing.kind == .file else {
                    presentOperationFailure(
                        message: String(
                            localized: "Can’t edit “\(name)”",
                            comment: "Edit-file failure title; %@ is the name."
                        ),
                        detail: String(
                            localized: "There’s already a folder with that name.",
                            comment: "Edit-file failure detail: name is a folder."
                        )
                    )
                    return
                }
                edit(existing)
                return
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try backend.createFile(at: target)
                }.value
                refreshCurrentDirectory(selecting: target)
                focusTable()
                openInEditor(target)
            } catch {
                presentOperationFailure(
                    message: String(
                        localized: "Can’t create “\(name)”",
                        comment: "Create-file failure title; %@ is the name."
                    ),
                    detail: describe(error)
                )
            }
        }
    }
}
