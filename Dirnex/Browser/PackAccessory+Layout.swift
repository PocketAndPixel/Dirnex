import AppKit
import DirnexCore

/// Building the pack sheet's accessory view.
///
/// Manual frames rather than a stack view, matching what the sheet already did — and the reason is
/// the one docs/NOTES.md records: an `NSStackView` that cannot fit its arranged views *compresses*
/// them, so a longer translation crushes a control instead of overflowing visibly. Everything here
/// is sized from measured text instead:
///
/// - the **label column** is the widest of the six localized captions, not a constant (48 pt fitted
///   English "Name:" and clipped Russian «Формат:»);
/// - the **footer** is measured at the accessory's own width, in its own font, in whatever language
///   is running, and the whole view is that much taller. An `NSAlert` takes its accessory's height
///   from the view's *frame*, and a wrapping `NSTextField` with no width constraint does not wrap —
///   it overruns — so both halves of that have to be settled here rather than left to Auto Layout.
///
/// Everything is built in the **expanded** state, passphrase block and all, and `PackAccessory`
/// collapses it if no cipher is chosen. That order is what keeps the footer honest: measuring it
/// while it is on screen holding its real text is the only way to know how tall the sheet has to be
/// when a cipher *is* chosen, and a footer measured empty would leave the sentence saying the files
/// are unrecoverable drawn outside the sheet.
extension PackAccessory {
    /// What the sheet opens with. Carried as a value so a sheet re-raised after a rejected
    /// passphrase comes back with every other choice the user already made still in it — the one
    /// thing not carried is the passphrase itself, which is exactly what they need to retype.
    struct Defaults {
        var baseName: String
        var format: ArchivePacking.Format = .zip
        var level: ArchivePacking.CompressionLevel = .normal
        var encryption: ArchiveEncryption = .none
        var namePrivacy: ArchiveNamePrivacy = .visible
    }

    /// Rows are laid out bottom-up: the footer sits on the floor, the name field on the ceiling.
    private enum Metrics {
        static let fieldWidth: CGFloat = 260
        static let popupWidth: CGFloat = 220
        static let labelGap: CGFloat = 8
        static let rowPitch: CGFloat = 30
        static let fieldHeight: CGFloat = 24
        static let popupHeight: CGFloat = 26
        static let labelHeight: CGFloat = 18
        /// How far a caption sits above its control's origin so the two read as centered: a 24 pt
        /// field and a 26 pt popup put an 18 pt label at different heights.
        static let labelRiseOverField: CGFloat = 3
        static let labelRiseOverPopup: CGFloat = 4
    }

    /// Where every row sits, once the footer has been measured and the label column sized.
    ///
    /// Computed as one value rather than a dozen locals so the arithmetic reads as the diagram it
    /// is: bottom-up from the footer, with each caption raised onto its own control.
    private struct Rows {
        let labelWidth: CGFloat
        let fieldX: CGFloat
        let width: CGFloat
        let height: CGFloat
        let hideNames: CGFloat
        let confirm: CGFloat
        let passphrase: CGFloat
        let encryption: CGFloat
        let level: CGFloat
        let format: CGFloat
        let name: CGFloat

        init(labelWidth: CGFloat, footerHeight: CGFloat) {
            self.labelWidth = labelWidth
            fieldX = labelWidth + Metrics.labelGap
            width = fieldX + Metrics.fieldWidth
            hideNames = footerHeight + 12
            confirm = hideNames + 28
            passphrase = confirm + Metrics.rowPitch
            encryption = passphrase + Metrics.rowPitch + 2
            level = encryption + Metrics.rowPitch + 2
            format = level + Metrics.rowPitch
            name = format + Metrics.rowPitch + 2
            height = name + Metrics.fieldHeight
        }

        /// Each caption's y, in the order the captions are built.
        var captionYs: [CGFloat] {
            [
                name + Metrics.labelRiseOverField,
                format + Metrics.labelRiseOverPopup,
                level + Metrics.labelRiseOverPopup,
                encryption + Metrics.labelRiseOverPopup,
                passphrase + Metrics.labelRiseOverField,
                confirm + Metrics.labelRiseOverField
            ]
        }
    }

    static func make(_ defaults: Defaults) -> PackAccessory {
        let labels = captions().map(label(_:))
        let labelWidth = ceil(labels.map { $0.intrinsicContentSize.width }.reduce(0, max))
        let footer = makeFooter(width: labelWidth + Metrics.labelGap + Metrics.fieldWidth)
        let rows = Rows(labelWidth: labelWidth, footerHeight: footer.frame.height)
        for (label, y) in zip(labels, rows.captionYs) {
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: Metrics.labelHeight)
        }

        let nameField = NSTextField(frame: field(x: rows.fieldX, y: rows.name))
        nameField.stringValue = defaults.baseName
        nameField.placeholderString = String(
            localized: "Archive name",
            comment: "Placeholder in the pack sheet's name field."
        )
        let formatPopup = formatPopup(rows: rows, selecting: defaults.format)
        let levelPopup = levelPopup(rows: rows, selecting: defaults.level)
        let encryptionPopup = encryptionPopup(rows: rows, selecting: defaults.encryption)
        let passphraseField = secureField(x: rows.fieldX, y: rows.passphrase)
        let confirmField = secureField(x: rows.fieldX, y: rows.confirm)
        let hideNames = hideNamesCheckbox(rows: rows, on: defaults.namePrivacy == .hidden)

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: rows.width, height: rows.height)
        )
        let controls: [NSView] = labels + [
            nameField, formatPopup, levelPopup, encryptionPopup,
            passphraseField, confirmField, hideNames, footer
        ]
        for subview in controls {
            container.addSubview(subview)
        }

        return PackAccessory(
            view: container,
            nameField: nameField,
            formatPopup: formatPopup,
            levelPopup: levelPopup,
            levelLabel: labels[2],
            encryptionPopup: encryptionPopup,
            passphraseField: passphraseField,
            confirmField: confirmField,
            hideNamesCheckbox: hideNames,
            // The split is the encryption row: it and everything above it survive a collapse and
            // slide down onto the floor the block below them vacates. That distance needs no
            // arithmetic of its own — the encryption row already sits `rows.encryption` points up,
            // which is by construction exactly the height of everything under it.
            encryptionRows: PackAccessory.EncryptionRows(
                hidden: [labels[4], labels[5], passphraseField, confirmField, hideNames, footer],
                shifted: Array(labels[0...3]) + [
                    nameField, formatPopup, levelPopup, encryptionPopup
                ],
                delta: rows.encryption
            )
        )
    }

    // MARK: - Control factories

    private static func captions() -> [String] {
        [
            // "Name:", "Passphrase:" and "Repeat:" are shared with the New Vault sheet. The key is
            // the English text, so both sites are one catalog entry — and `String(localized:
            // comment:)` takes a `StaticString`, so the comment cannot be hoisted and has to be
            // repeated verbatim in both files or `xcstringstool` keeps whichever it saw last
            // (docs/NOTES.md). Hence the deliberately dialog-neutral wording.
            String(
                localized: "Name:",
                comment: "Field label for the name of the thing being created. Pack and New Vault."
            ),
            String(localized: "Format:", comment: "Pack sheet field label for the archive format."),
            String(
                localized: "Compression:",
                comment: "Pack sheet field label for the compression level."
            ),
            String(
                localized: "Encryption:",
                comment: "Pack sheet field label for the encryption cipher."
            ),
            String(
                localized: "Passphrase:",
                comment: "Field label for the passphrase. Pack sheet and New Vault sheet."
            ),
            String(
                localized: "Repeat:",
                comment: "Field label for retyping the passphrase to confirm it. Pack and New Vault."
            )
        ]
    }

    /// Every popup draws through the catalog, not through `displayName`: the core's English is data
    /// here, and a literal at a variable-driven call site would extract nothing.
    private static func formatPopup(
        rows: Rows,
        selecting format: ArchivePacking.Format
    ) -> NSPopUpButton {
        let all = ArchivePacking.Format.allCases
        let popup = popup(
            x: rows.fieldX,
            y: rows.format,
            titles: all.map { LocalizedCatalog.title(for: $0) }
        )
        popup.selectItem(at: all.firstIndex(of: format) ?? 0)
        return popup
    }

    private static func levelPopup(
        rows: Rows,
        selecting level: ArchivePacking.CompressionLevel
    ) -> NSPopUpButton {
        let all = ArchivePacking.CompressionLevel.allCases
        let popup = popup(
            x: rows.fieldX,
            y: rows.level,
            titles: all.map { LocalizedCatalog.title(for: $0) }
        )
        popup.selectItem(at: all.firstIndex(of: level) ?? 0)
        return popup
    }

    private static func encryptionPopup(
        rows: Rows,
        selecting encryption: ArchiveEncryption
    ) -> NSPopUpButton {
        let all = ArchiveEncryption.allCases
        let popup = popup(
            x: rows.fieldX,
            y: rows.encryption,
            titles: all.map { LocalizedCatalog.title(for: $0) }
        )
        popup.selectItem(at: all.firstIndex(of: encryption) ?? 0)
        return popup
    }

    private static func hideNamesCheckbox(rows: Rows, on: Bool) -> NSButton {
        let checkbox = NSButton(
            checkboxWithTitle: LocalizedCatalog.title(for: ArchiveNamePrivacy.hidden),
            target: nil,
            action: nil
        )
        checkbox.frame = NSRect(
            x: rows.fieldX, y: rows.hideNames, width: Metrics.fieldWidth, height: 18
        )
        checkbox.state = on ? .on : .off
        checkbox.toolTip = String(
            localized: """
            A zip always lists its file names in the clear, whatever the passphrase. This puts \
            everything inside one archive first, so only that one name is visible — the recipient \
            unpacks twice.
            """,
            comment: "Tooltip for the pack sheet's “Hide file names” checkbox."
        )
        return checkbox
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private static func field(x: CGFloat, y: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: Metrics.fieldWidth, height: Metrics.fieldHeight)
    }

    private static func secureField(x: CGFloat, y: CGFloat) -> NSSecureTextField {
        let secure = NSSecureTextField(frame: field(x: x, y: y))
        secure.placeholderString = String(
            localized: "Required",
            comment: "Placeholder in a passphrase field. Pack sheet and New Vault sheet."
        )
        return secure
    }

    private static func popup(x: CGFloat, y: CGFloat, titles: [String]) -> NSPopUpButton {
        let popup = NSPopUpButton(
            frame: NSRect(x: x, y: y, width: Metrics.popupWidth, height: Metrics.popupHeight)
        )
        for title in titles {
            popup.addItem(withTitle: title)
        }
        return popup
    }

    /// The footer, sized for the note it will hold in *this* language.
    ///
    /// Built with the note already in it so `sizeThatFits` measures the real thing; `PackAccessory`
    /// clears it in `init` when no cipher is chosen. Measuring the empty state and growing later
    /// would leave the alert's reserved height a line short, with the last sentence — the one saying
    /// the files are unrecoverable — drawn outside the sheet.
    private static func makeFooter(width: CGFloat) -> NSTextField {
        let footer = NSTextField(wrappingLabelWithString: PackAccessory.encryptionNote)
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.isSelectable = false
        footer.preferredMaxLayoutWidth = width
        let fitted = footer.sizeThatFits(
            NSSize(width: width, height: .greatestFiniteMagnitude)
        )
        footer.frame = NSRect(x: 0, y: 0, width: width, height: ceil(fitted.height))
        return footer
    }
}
