import AppKit
import DirnexCore

/// The administrator escalation for a Save that needs root (PLAN.md §M14 Slice 5) — a file the user
/// does not own, or a system-immutable one they do. The probe matrix says this is the *rare* case, so
/// it is a deliberate exception the user reaches at Save, never a blanket "try again as admin".
///
/// Both paths the plan settled on are offered together, from the one command the core built:
///
/// - **Authenticate** runs it in-app through the standard macOS auth dialog (`AdministratorShell`).
/// - **Or run it yourself** shows the same command in a read-only, copyable field — the honest escape
///   hatch for someone who would rather not hand an app their admin password, and the half that is
///   safe enough to be always present.
///
/// The command is built and quoted in `EscalatedAttributeCommand`; this file only presents it and, on
/// success, journals what actually landed. Two aspects a stock shell cannot reproduce — the Created
/// date and a non-reproducible ACL — are stated here as the core reported them, and excluded from the
/// journal so ⌘Z never tries to revert a change that never happened.
extension AttributesController {
    /// Offer the escalation for a root-only Save. The command is derived from the *same* diff and ACL
    /// the flat Save would have applied, so the two paths are provably the same change.
    func presentEscalation(
        diff: AttributeDiff,
        old: FileAttributes,
        aclChanged: Bool,
        newList: AccessControlList,
        sender: Any?
    ) {
        let plan = AttributeChangePlan(
            diff: diff,
            current: old,
            actsOnLink: snapshot.isSymlink,
            accessControlList: aclChanged ? newList : nil
        )
        let command = EscalatedAttributeCommand.build(
            for: plan, path: snapshot.entry.path.path, current: old
        )

        let canRun = command.hasCommands
        let alert = AdministratorEscalationAlert.make(
            body: canRun
                ? String(
                    localized: """
                    Authenticate to make this change as an administrator, or run the command below \
                    yourself.
                    """,
                    comment: "Attributes escalation body: how to apply a root-only change."
                )
                : AdministratorEscalationAlert.nothingToRun,
            omissions: command.omissions,
            terminalCommand: command.terminalCommand,
            canRun: canRun
        )

        let onAuthenticate: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, canRun, response == .alertFirstButtonReturn else { return }
            authenticateAndApply(
                command,
                old: old,
                aclChanged: aclChanged,
                newList: newList,
                sender: sender
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: onAuthenticate)
        } else {
            onAuthenticate(alert.runModal())
        }
    }

    // MARK: - Running it

    private func authenticateAndApply(
        _ command: EscalatedAttributeCommand,
        old: FileAttributes,
        aclChanged: Bool,
        newList: AccessControlList,
        sender: Any?
    ) {
        Task { @MainActor in
            do {
                try await AdministratorShell.run([command.scriptBody])
                journalEscalatedChange(command, old: old, aclChanged: aclChanged, newList: newList)
                onApplied?()
                dismiss(sender)
            } catch AdministratorShell.Failure.cancelled {
                // The user dismissed the auth dialog — leave the Get Info sheet open, unchanged.
            } catch let AdministratorShell.Failure.failed(message) {
                presentEscalationFailure(message)
            } catch {
                presentEscalationFailure("")
            }
        }
    }

    /// Journal **what actually landed**, not what was asked. An omitted Created date or ACL never
    /// reached disk, so recording it would make ⌘Z attempt to revert a change that never happened.
    /// The undo itself will need root again (nothing about a file you do not own is yours to put
    /// back), and ⌘Z asks for it in this same dialog before it takes the step (PLAN.md §M40 Slice
    /// 5, `UndoController.undo`), so escalated changes journal like any other.
    private func journalEscalatedChange(
        _ command: EscalatedAttributeCommand,
        old: FileAttributes,
        aclChanged: Bool,
        newList: AccessControlList
    ) {
        var applied = working
        if command.omissions.contains(.creationDate) { applied.creationDate = old.creationDate }
        let recordedACL: (old: AccessControlList, new: AccessControlList)? =
            aclChanged && !command.omissions.contains(.accessControlList)
                ? (old: snapshot.accessControlList, new: newList)
                : nil
        if let record = UndoRecord.attributeChange(
            at: snapshot.entry.path,
            actsOnLink: snapshot.isSymlink,
            from: old,
            to: applied,
            accessControlList: recordedACL
        ) {
            recordUndo?(record)
        }
    }

    private func presentEscalationFailure(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Couldn’t change “\(snapshot.entry.name)”",
            comment: "Attributes save failure title; %@ is the item name."
        )
        alert.informativeText = message.isEmpty
            ? String(
                localized: "The administrator command didn’t finish.",
                comment: "Attributes escalation failure body when the tool gave no message."
            )
            : message
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        present(alert)
    }
}
