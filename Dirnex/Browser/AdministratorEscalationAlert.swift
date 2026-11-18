import AppKit
import DirnexCore

/// The administrator dialog for a change that needs root (PLAN.md §M14 Slice 5, §M40 Slice 4): one
/// item from its Get Info sheet, or many from a multi-selection Save or a recursive run's report.
///
/// Both paths M14 settled on are offered together, from the one command the core built:
/// **Authenticate…** runs it through the macOS password dialog (`AdministratorShell`), and the "run it
/// yourself" field shows the same command to copy, for someone who would rather not hand an app their
/// password. A batch too long for one command line has no field, since `sudo` could not run it either,
/// and the dialog says so.
@MainActor
enum AdministratorEscalationAlert {
    /// The alert. `body` is its first paragraph; each omission follows as a sentence of its own.
    /// With `canRun` false there is nothing to authenticate, and the one button acknowledges.
    /// `title` replaces "This change needs an administrator", for an undo or a redo.
    static func make(
        title: String? = nil,
        body: String,
        omissions: Set<EscalatedAttributeCommand.Omission>,
        terminalCommand: String?,
        canRun: Bool
    ) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title ?? String(
            localized: "This change needs an administrator",
            comment: "Attributes save alert title: the change requires root privileges."
        )
        alert.informativeText = ([body] + omissionSentences(omissions)).joined(separator: "\n\n")
        if canRun, let terminalCommand {
            alert.accessoryView = AdministratorCommandView(command: terminalCommand)
        }
        if canRun {
            alert.addButton(withTitle: String(
                localized: "Authenticate…",
                comment: "Button that runs a change through the macOS administrator auth dialog."
            ))
            alert.addButton(
                withTitle: String(localized: "Cancel", comment: "Button that discards an edit.")
            )
        } else {
            alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button."))
        }
        alert.enableEscapeToCancel()
        return alert
    }

    /// The title for an undo or a redo that needs root (PLAN.md §M40 Slice 5). The body is the
    /// batch's, since putting items back is changing them.
    static func title(for direction: UndoDirection) -> String {
        switch direction {
        case .undo:
            String(
                localized: "Undoing this change needs an administrator",
                comment: "Alert title when ⌘Z has to put back items only an administrator can change."
            )
        case .redo:
            String(
                localized: "Redoing this change needs an administrator",
                comment: "Alert title when ⇧⌘Z has to change items only an administrator can change."
            )
        }
    }

    /// The first paragraph when nothing the elevated command can do remains.
    static var nothingToRun: String {
        String(
            localized: "This change can’t be made as an administrator from here.",
            comment: "Attributes escalation body when nothing the elevated command can do remains."
        )
    }

    /// The first paragraph for a batch: how many items, and whether the command is offered to run
    /// by hand.
    static func batchBody(count: Int, offersCommand: Bool) -> String {
        offersCommand
            ? String(
                localized: """
                Authenticate to change \(count) items as an administrator, or run the command below \
                yourself.
                """,
                comment: "Batch attributes escalation body; %lld is how many items need root. Plural."
            )
            : String(
                localized: """
                Authenticate to change \(count) items as an administrator. The command is too long to \
                run in Terminal yourself.
                """,
                comment: """
                Batch attributes escalation body when the command does not fit one command line; \
                %lld is how many items need root. Plural.
                """
            )
    }

    /// A whole sentence for each aspect the elevated command leaves out.
    static func omissionSentences(_ omissions: Set<EscalatedAttributeCommand.Omission>) -> [String] {
        var lines: [String] = []
        if omissions.contains(.creationDate) {
            lines.append(String(
                localized: "The Created date can’t be changed this way and will be left as it is.",
                comment: "Attributes escalation note: the birth date is not set by the elevated command."
            ))
        }
        if omissions.contains(.accessControlList) {
            lines.append(String(
                localized: """
                The access-control list can’t be changed this way and will be left as it is.
                """,
                comment: "Attributes escalation note: the ACL is not reproduced by the elevated command."
            ))
        }
        return lines
    }
}

/// The "run it yourself" accessory: a label, the read-only command and a Copy button.
///
/// Its own view so the Copy button has a target that lives exactly as long as the alert: an
/// `NSAlert` retains its accessory, and `NSButton.target` is weak.
final class AdministratorCommandView: NSStackView {
    let field: NSTextField

    init(command: String) {
        field = NSTextField(string: command)
        super.init(frame: .zero)

        let label = NSTextField(labelWithString: String(
            localized: "Or run this yourself in Terminal:",
            comment: "Label above the copyable administrator command in the attributes escalation."
        ))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.keepToOneLine(truncating: .byTruncatingMiddle)
        // A fixed width so the command truncates rather than stretching the alert, and so the stack
        // has a definite size to report.
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let copy = NSButton(
            title: String(localized: "Copy", comment: "Button that copies text to the clipboard."),
            target: self,
            action: #selector(copyCommand(_:))
        )
        copy.bezelStyle = .rounded
        copy.setContentHuggingPriority(.required, for: .horizontal)

        let commandRow = NSStackView(views: [field, copy])
        commandRow.orientation = .horizontal
        commandRow.spacing = 8
        commandRow.alignment = .firstBaseline

        orientation = .vertical
        alignment = .leading
        spacing = 6
        addArrangedSubview(label)
        addArrangedSubview(commandRow)
        // An NSAlert reserves vertical space for its accessory from the view's *frame*, so give the
        // stack a concrete one sized to its content — a pure-Auto-Layout view reports a zero frame and
        // the alert then draws it overlapping the informative text (found live, M14).
        layoutSubtreeIfNeeded()
        frame = NSRect(origin: .zero, size: fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func copyCommand(_ sender: Any?) {
        let text = field.stringValue
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
