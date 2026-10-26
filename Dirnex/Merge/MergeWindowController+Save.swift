import AppKit
import DirnexCore

/// Saving the merge window's result (PLAN.md §M34 Slice 3): ⌘S and the Save button, held back while
/// a conflict is open, and the question when the window closes or the app quits with choices that
/// are not saved.
///
/// The result is written into the target as the compare window writes a side
/// (`ComparedFileSave`): encoded in yours' encoding with yours' byte-order mark, checked against the
/// file as it was read, kept in the undo store and written in place, inside a coordinated write.
/// A save is refused while any conflict has no choice, so no conflict marker is ever written. A
/// server file's result then goes on up (`MergeSaving.carry`, Slice 4).
extension MergeWindowController {
    /// Whether the result as it stands is not in the file: never saved, or chosen differently since.
    var hasUnsavedResult: Bool {
        guard let merge else { return false }
        return savedChoices != merge.choices
    }

    /// Whether closing would lose choices made here: some are made and not saved. A merge whose
    /// changes all merged on their own has none, and is merged the same way when opened again.
    var hasUnsavedChoices: Bool {
        guard let merge else { return false }
        return merge.choices != savedChoices ?? Array(repeating: nil, count: merge.choices.count)
    }

    /// Whether Save would write: every conflict has a choice, and the file does not hold them yet.
    var canSave: Bool {
        merge?.isResolved == true && hasUnsavedResult && !isSaving
    }

    /// ⌘S or Save. With a conflict open it beeps and goes to the first open one.
    func saveFromKey() {
        guard let merge, !isSaving else { return NSSound.beep() }
        guard merge.isResolved else {
            NSSound.beep()
            if let open = merge.choices.firstIndex(where: { $0 == nil }) { goToConflict(open) }
            return
        }
        guard hasUnsavedResult else { return NSSound.beep() }
        Task { await saveResult() }
    }

    /// Write the result into the target, asking first when the file changed since it was read.
    /// `true` when it was written.
    @discardableResult
    func saveResult() async -> Bool {
        guard let merge, merge.isResolved, !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        let document = merge.result
        let choices = merge.choices
        let request = saving.undo()
        let undo = request.store.map { ComparedFileSave.UndoCopy(store: $0, live: request.live) }
        var overwriting = false
        while true {
            let target = target
            let answer = overwriting
            let result = await BlockingWork.run {
                Result { () throws(ComparedFileSave.Failure) in
                    try ComparedFileSave.save(
                        document,
                        to: target,
                        overwritingChanges: answer,
                        undo: undo
                    )
                }
            }
            switch result {
            case let .success(saved):
                self.target = saved.target
                savedChoices = choices
                if let record = saved.undo { saving.journal(record) }
                await saving.carry?(window)
                return true
            case .failure(.changedSinceRead):
                guard await CompareWindowController.askToSaveAnyway(input.name, over: window) else {
                    return false
                }
                overwriting = true
            case let .failure(.unencodable(line, character)):
                await CompareWindowController.reportSaveFailure(
                    input.name,
                    detail: CompareWindowController.unencodableDetail(
                        character,
                        line: line,
                        in: document.encoding
                    ),
                    over: window
                )
                return false
            case let .failure(.failed(error)):
                await CompareWindowController.reportSaveFailure(
                    input.name,
                    detail: VFSErrorText.sentence(for: error),
                    over: window
                )
                return false
            }
        }
    }

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A second ⌘W or ⎋ while a question is up asks nothing more, and a save carrying the
        // result on to a server may still put one on this window.
        guard sender.attachedSheet == nil, !isSaving else { return false }
        guard hasUnsavedChoices else { return true }
        Task { await closeAfterAsking() }
        return false
    }

    /// Ask about the choices not saved, then close unless the answer was Cancel or a save failed.
    func closeAfterAsking() async {
        switch await askBeforeClosing() {
        case .save:
            guard await saveResult() else { return }
            window?.close()
        case .discard:
            // `close` does not ask the delegate again, as `performClose` would.
            window?.close()
        case .cancel:
            break
        }
    }

    /// Whether any open window has choices a save could keep, which quitting would lose.
    static var anyUnsaved: Bool {
        open.contains { $0.hasUnsavedChoices }
    }

    /// Ask each window with choices not saved in turn before the app quits. `false` when the user
    /// cancelled, or a save they asked for did not happen.
    static func confirmQuit() async -> Bool {
        for controller in open where controller.hasUnsavedChoices {
            controller.showWindow(nil)
            switch await controller.askBeforeClosing() {
            case .save:
                guard await controller.saveResult() else { return false }
            case .discard:
                continue
            case .cancel:
                return false
            }
        }
        return true
    }

    /// Save, Don't Save or Cancel once every conflict has a choice, as any Mac app asks. With a
    /// conflict still open there is nothing a save could write, so the question is only whether to
    /// drop the choices: Cancel, the default, or Don't Save. ⎋ cancels and ⌘D is Don't Save.
    func askBeforeClosing() async -> CompareWindowController.CloseAnswer {
        let open = merge?.openConflictCount ?? 0
        let alert = NSAlert()
        if open == 0 {
            alert.messageText = String(
                localized: "Do you want to save the merge of “\(input.name)”?",
                comment: "Merge window close prompt title; %@ is the name of the file being merged."
            )
            alert.informativeText = String(
                localized: "Your choices will be lost if you don’t save them.",
                comment: "Merge window close prompt body."
            )
            alert.addButton(
                withTitle: String(localized: "Save", comment: "Button that saves the edited files.")
            )
        } else {
            alert.messageText = String(
                localized: "Close the merge of “\(input.name)” without saving?",
                comment: "Merge window close prompt title while a conflict is open; %@ is a file name."
            )
            alert.informativeText = String(
                localized: """
                \(open) conflicts are still open, so the result can’t be saved yet. The choices \
                made here will be lost.
                """,
                comment: "Merge window close prompt body; %lld is how many conflicts have no choice yet."
            )
        }
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Cancel button."))
        let discard = alert.addButton(withTitle: String(
            localized: "Don’t Save",
            comment: "Button that closes the compare window and drops the copies made in it."
        ))
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        let cancel: NSApplication.ModalResponse = open == 0
            ? .alertSecondButtonReturn
            : .alertFirstButtonReturn
        alert.enableEscapeToCancel(safe: cancel)
        switch (open == 0, await alert.sheetAnswer(over: window, whenUnasked: cancel)) {
        case (true, .alertFirstButtonReturn): return .save
        case (true, .alertThirdButtonReturn), (false, .alertSecondButtonReturn): return .discard
        default: return .cancel
        }
    }
}
