import AppKit
import DirnexCore

/// The export sheet's form (PLAN.md §M39 ▸ Slice 12): the format, the file's name and the folder it
/// goes to, the last two both editable, as Oleg had it — "a sheet with the name and the other pane's
/// folder".
///
/// Pack's shape (`PackAccessory`), for Pack's reasons: manual frames measured from the localized
/// captions, so a longer translation widens the label column rather than crushing a field; an error
/// row under the form that grows the sheet by the height its sentence takes, because an `NSAlert`
/// takes its accessory's height from the frame; and the Export button retargeted, so the sheet stays
/// up while a name or a folder is wrong.
///
/// **The name follows the format.** Choosing PDF turns `README.html` into `README.pdf`, and only an
/// extension that is the old format's gives way (``DirnexCore/MarkdownExport/renamed(_:from:to:)``),
/// so a name the user typed without one, or with one of their own, is left alone.
@MainActor
final class MarkdownExportAccessory: NSObject {
    let view: NSView
    let formatPopup: NSPopUpButton
    let nameField: NSTextField
    let folderField: NSTextField
    /// Why the last Export did not go ahead. Hidden and taking no height until there is something
    /// to say (``showError(_:)``).
    let errorLabel: NSTextField

    /// Called after ``view``'s frame changes, for the presenter to re-lay out the alert around it.
    var onHeightChange: (() -> Void)?
    /// What pressing Export does, once ``routeExport(through:)`` has taken the button over.
    var onExport: (() -> Void)?
    /// The missing folder the last press said it would make on the next one (2026-11-18). A press
    /// whose folder field still names it makes the folder; one naming another folder asks again.
    var folderToCreate: VFSPath?

    /// The format the name's extension was last made to follow.
    private var shownFormat: MarkdownExport.Format
    /// The height the error row adds, gap included; zero while it is hidden.
    private var errorRowHeight: CGFloat = 0
    private weak var exportButton: NSButton?

    private init(
        view: NSView,
        formatPopup: NSPopUpButton,
        nameField: NSTextField,
        folderField: NSTextField,
        errorLabel: NSTextField,
        format: MarkdownExport.Format
    ) {
        self.view = view
        self.formatPopup = formatPopup
        self.nameField = nameField
        self.folderField = folderField
        self.errorLabel = errorLabel
        shownFormat = format
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
    }

    /// The chosen format. The popup is built from `Format.allCases` in order.
    var format: MarkdownExport.Format {
        MarkdownExport.Format.allCases[max(0, formatPopup.indexOfSelectedItem)]
    }

    /// Make `button`, the alert's Export, run ``onExport`` instead of ending the sheet. A click,
    /// Return and keypad Enter all reach it through `performClick`.
    func routeExport(through button: NSButton) {
        exportButton = button
        button.target = self
        button.action = #selector(exportPressed)
    }

    @objc private func exportPressed(_ sender: Any?) {
        onExport?()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        nameField.stringValue = MarkdownExport.renamed(
            nameField.stringValue,
            from: shownFormat,
            to: format
        )
        shownFormat = format
    }

    /// Hold the form still while the folder is being looked for on its backend, which for a server
    /// is a request: nothing can be changed, and Export cannot be pressed twice.
    func setBusy(_ busy: Bool) {
        for control in [formatPopup, nameField, folderField] as [NSControl] {
            control.isEnabled = !busy
        }
        exportButton?.isEnabled = !busy
    }

    /// Say why the export did not go ahead, under the form, or with `nil` take the row away.
    func showError(_ message: String?) {
        let text = message ?? ""
        errorLabel.stringValue = text
        errorLabel.isHidden = text.isEmpty
        let width = view.frame.width
        let labelHeight = text.isEmpty
            ? 0
            : ceil(errorLabel.sizeThatFits(
                NSSize(width: width, height: .greatestFiniteMagnitude)
            ).height)
        let rowHeight = text.isEmpty ? 0 : labelHeight + Metrics.errorGap
        errorLabel.frame = NSRect(x: 0, y: 0, width: width, height: labelHeight)
        let shift = rowHeight - errorRowHeight
        guard shift != 0 else { return }
        errorRowHeight = rowHeight
        for subview in view.subviews where subview !== errorLabel {
            subview.frame.origin.y += shift
        }
        view.frame.size.height += shift
        onHeightChange?()
    }

    // MARK: - Building

    /// Rows laid out bottom-up: the folder on the floor, the format popup on the ceiling.
    private enum Metrics {
        static let fieldWidth: CGFloat = 320
        static let popupWidth: CGFloat = 120
        static let labelGap: CGFloat = 8
        static let fieldHeight: CGFloat = 24
        static let popupHeight: CGFloat = 26
        static let labelHeight: CGFloat = 18
        static let folderY: CGFloat = 0
        static let nameY: CGFloat = 30
        static let formatY: CGFloat = 62
        static let height: CGFloat = formatY + popupHeight
        static let errorGap: CGFloat = 8
    }

    /// The form, opening on `format`, `name` and the folder `folder` spells.
    static func make(
        format: MarkdownExport.Format,
        name: String,
        folder: String
    ) -> MarkdownExportAccessory {
        let captions = [
            String(
                localized: "Format:",
                comment: "Field label for a file format. Pack sheet and Export sheet."
            ),
            String(
                localized: "Name:",
                comment: "Field label for the name of the thing being created. Pack and New Vault."
            ),
            String(
                localized: "Folder:",
                comment: "Export sheet field label for the folder the exported file is saved in."
            )
        ]
        let labels = captions.map { caption -> NSTextField in
            let label = NSTextField(labelWithString: caption)
            label.alignment = .right
            return label
        }
        let labelWidth = ceil(labels.map(\.intrinsicContentSize.width).reduce(0, max))
        let fieldX = labelWidth + Metrics.labelGap
        let width = fieldX + Metrics.fieldWidth
        let rises: [CGFloat] = [Metrics.formatY + 4, Metrics.nameY + 3, Metrics.folderY + 3]
        for (label, y) in zip(labels, rises) {
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: Metrics.labelHeight)
        }

        let formatPopup = NSPopUpButton(frame: NSRect(
            x: fieldX, y: Metrics.formatY, width: Metrics.popupWidth, height: Metrics.popupHeight
        ))
        // The formats' own names, which no language translates.
        formatPopup.addItems(withTitles: MarkdownExport.Format.allCases.map(\.displayName))
        formatPopup.selectItem(at: MarkdownExport.Format.allCases.firstIndex(of: format) ?? 0)
        let nameField = textField(x: fieldX, y: Metrics.nameY, text: name)
        let folderField = textField(x: fieldX, y: Metrics.folderY, text: folder)

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = false
        errorLabel.preferredMaxLayoutWidth = width
        errorLabel.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        errorLabel.isHidden = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: Metrics.height))
        for subview in labels + [formatPopup, nameField, folderField, errorLabel] {
            container.addSubview(subview)
        }
        return MarkdownExportAccessory(
            view: container,
            formatPopup: formatPopup,
            nameField: nameField,
            folderField: folderField,
            errorLabel: errorLabel,
            format: format
        )
    }

    private static func textField(x: CGFloat, y: CGFloat, text: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(
            x: x, y: y, width: Metrics.fieldWidth, height: Metrics.fieldHeight
        ))
        field.keepToOneLine()
        field.stringValue = text
        return field
    }
}

extension MarkdownExport.Format {
    /// The name the sheet's popup draws: the format's own, the same in every language.
    var displayName: String {
        switch self {
        case .html: "HTML"
        case .pdf: "PDF"
        }
    }
}
