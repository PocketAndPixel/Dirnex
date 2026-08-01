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

        let alert = NSAlert()
        alert.messageText = String(
            localized: "This change needs an administrator",
            comment: "Attributes save alert title: the change requires root privileges."
        )
        alert.informativeText = escalationInformativeText(command)
        if let terminal = command.terminalCommand {
            alert.accessoryView = makeEscalationAccessory(terminal)
        }

        let canRun = command.hasCommands
        if canRun {
            alert.addButton(withTitle: String(
                localized: "Authenticate…",
                comment: "Button that runs a change through the macOS administrator auth dialog."
            ))
            alert.addButton(
                withTitle: String(localized: "Cancel", comment: "Button that discards an edit.")
            )
        } else {
            // The only change was one the elevated command cannot reproduce (see the omission notes),
            // so there is nothing to authenticate — just acknowledge.
            alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        }
        alert.enableEscapeToCancel()

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

    // MARK: - The dialog's words

    /// The body: what the escalation will do, then a whole sentence per aspect it will *not*.
    private func escalationInformativeText(_ command: EscalatedAttributeCommand) -> String {
        var lines: [String] = []
        if command.hasCommands {
            lines.append(String(
                localized: """
                Authenticate to make this change as an administrator, or run the command below \
                yourself.
                """,
                comment: "Attributes escalation body: how to apply a root-only change."
            ))
        } else {
            lines.append(String(
                localized: "This change can’t be made as an administrator from here.",
                comment: "Attributes escalation body when nothing the elevated command can do remains."
            ))
        }
        if command.omissions.contains(.creationDate) {
            lines.append(String(
                localized: "The Created date can’t be changed this way and will be left as it is.",
                comment: "Attributes escalation note: the birth date is not set by the elevated command."
            ))
        }
        if command.omissions.contains(.accessControlList) {
            lines.append(String(
                localized: """
                The access-control list can’t be changed this way and will be left as it is.
                """,
                comment: "Attributes escalation note: the ACL is not reproduced by the elevated command."
            ))
        }
        return lines.joined(separator: "\n\n")
    }

    /// The copyable "or run it yourself" field and its Copy button.
    private func makeEscalationAccessory(_ terminalCommand: String) -> NSView {
        let label = NSTextField(labelWithString: String(
            localized: "Or run this yourself in Terminal:",
            comment: "Label above the copyable administrator command in the attributes escalation."
        ))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        let field = NSTextField(string: terminalCommand)
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        // A fixed width so the command truncates rather than stretching the alert, and so the stack
        // below has a definite size to report.
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        escalationCommandField = field

        let copy = NSButton(
            title: String(localized: "Copy", comment: "Button that copies text to the clipboard."),
            target: self,
            action: #selector(copyEscalationCommand(_:))
        )
        copy.bezelStyle = .rounded
        copy.setContentHuggingPriority(.required, for: .horizontal)

        let commandRow = NSStackView(views: [field, copy])
        commandRow.orientation = .horizontal
        commandRow.spacing = 8
        commandRow.alignment = .firstBaseline

        let stack = NSStackView(views: [label, commandRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // An NSAlert reserves vertical space for its accessory from the view's *frame*, so give the
        // stack a concrete one sized to its content — a pure-Auto-Layout view reports a zero frame and
        // the alert then draws it overlapping the informative text (found live).
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }

    @objc func copyEscalationCommand(_ sender: Any?) {
        guard let text = escalationCommandField?.stringValue, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                try await AdministratorShell.run(command.scriptBody)
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
    /// back), and `UndoJournal` refuses that with a stated reason — the same asymmetric-undo shape
    /// Slice 4 already handles, so escalated changes journal like any other and simply cannot be
    /// reversed without authenticating again.
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
