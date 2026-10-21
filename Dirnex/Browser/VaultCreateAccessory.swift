import AppKit
import DirnexCore

/// The New Vault sheet's controls (PLAN.md §M19 Slice 2).
///
/// Manual frames and a measured label column, for the reason the pack sheet records: an
/// `NSStackView` that cannot fit its arranged views *compresses* them, so a longer translation
/// crushes a control instead of overflowing visibly (docs/NOTES.md). The footer is measured at the
/// accessory's own width in whatever language is running, because an `NSAlert` takes its accessory's
/// height from the view's **frame** and a wrapping `NSTextField` with no width constraint does not
/// wrap — it overruns.
///
/// **Four rows, and the two that are missing are decisions.** There is no image-kind popup: PLAN.md
/// §M19 chose the sparse bundle, and the measurement behind it is why offering the alternative would
/// be a trap rather than a choice — a growable 10 GB vault costs **23 MB and ~1 s**, where a fixed
/// one of the same size writes all 10 GB up front (measured: a 2 GB fixed image took 4.0 s, so a
/// large one is minutes of waiting for a worse result). `DiskImageArguments.Kind.fixed` stays in the
/// core, tested, for the day something wants it. And there is no "save the passphrase" checkbox: the
/// passphrase is filed in the Keychain, which is where the user's other secrets already are and
/// which they can revoke there.
///
/// **The sheet stays up until the vault exists.** A mismatched passphrase, a name already taken or
/// `hdiutil` refusing is said in ``errorLabel`` under the form, with the name and size the user
/// chose still in place, so they fix the one thing that was wrong rather than starting over — the
/// Connect sheet's rule. ``routeCreate(through:)`` is what makes that possible on an `NSAlert`,
/// which otherwise ends its sheet on every button press before anything has been checked.
///
/// An object because it is the Create button's target, and kept alive by the sheet's completion
/// closure, which captures it: `NSControl.target` is weak. Main-actor isolated, like every control
/// it holds.
@MainActor
final class VaultCreateAccessory: NSObject {
    let view: NSView
    let nameField: NSTextField
    let sizeField: NSTextField
    let passphraseField: NSSecureTextField
    let confirmField: NSSecureTextField
    /// Why the last Create did not make a vault, at the bottom of the form. Hidden and taking no
    /// height until there is something to say (``showError(_:)``).
    let errorLabel: NSTextField

    /// Called after ``view``'s frame changes, for the presenter to re-lay out the alert around it —
    /// `NSAlert` sizes itself from the accessory's frame, so a grown error row needs `layout()`.
    var onHeightChange: (() -> Void)?

    /// What pressing Create does, once ``routeCreate(through:)`` has taken the button over.
    var onCreate: (() -> Void)?

    /// The height the error row adds, gap included; zero while it is hidden.
    private var errorRowHeight: CGFloat = 0

    /// Sizes in gigabytes. A *ceiling*, not an allocation — the whole reason a vault is a sparse
    /// bundle — so the default is generous rather than careful, and the hint beside the field says
    /// what it costs, since "how big should it be" is otherwise a question with no way to answer it.
    static let defaultSizeGigabytes = 100
    private static let maximumSizeGigabytes = 2_000_000

    init(
        view: NSView,
        nameField: NSTextField,
        sizeField: NSTextField,
        passphraseField: NSSecureTextField,
        confirmField: NSSecureTextField,
        errorLabel: NSTextField
    ) {
        self.view = view
        self.nameField = nameField
        self.sizeField = sizeField
        self.passphraseField = passphraseField
        self.confirmField = confirmField
        self.errorLabel = errorLabel
        super.init()
    }

    /// Make `button` — the alert's Create — run ``onCreate`` instead of ending the sheet.
    ///
    /// A click, Return and keypad Enter all reach the button through `performClick`, the
    /// `AlertKeyCatcher` included, so retargeting it covers every way of pressing it. Probed on
    /// macOS 26: the target survives presentation, a click leaves the sheet up, and a disabled
    /// button runs nothing — which is how a create already in flight cannot be started twice.
    func routeCreate(through button: NSButton) {
        button.target = self
        button.action = #selector(createPressed)
    }

    @objc private func createPressed(_ sender: Any?) {
        onCreate?()
    }

    /// The vault's name, trimmed, falling back to a sensible one rather than refusing — an empty
    /// name is a slip, and `DiskImageArguments.vaultPath` has the same fallback for the same reason.
    var name: String {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultName : trimmed
    }

    /// The declared ceiling in megabytes, clamped into a range `hdiutil` will accept. A field that
    /// reads as `0`, `-4` or the user's phone number becomes the default rather than an error: the
    /// number is a ceiling nobody can be wrong about in a way worth a dialog.
    var megabytes: Int {
        let typed = Int(sizeField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        let gigabytes = (1...Self.maximumSizeGigabytes).contains(typed)
            ? typed
            : Self.defaultSizeGigabytes
        return gigabytes * 1024
    }

    static let defaultName = String(
        localized: "Vault",
        comment: "Default name for a new encrypted vault, and its volume name once unlocked."
    )

    /// What a user must know *before* choosing a passphrase.
    ///
    /// PLAN.md §6 makes this wording a milestone deliverable rather than a detail: a forgotten
    /// passphrase is the only failure in Dirnex that is silent, total and permanent — no undo
    /// journal, no Trash, no support call. The second sentence is the one that makes the first
    /// actionable: it says where the passphrase is kept, so "I'll never remember this" has an answer
    /// that is not "then don't use a vault".
    /// Internal because the layout has to *measure* it.
    static let passphraseNote = String(
        localized: """
        If you forget this passphrase everything in the vault is gone — there is no way to recover \
        it, and no one can unlock it for you. Dirnex saves it in your Keychain so this Mac won’t \
        ask again.
        """,
        comment: """
        Note under the New Vault sheet's passphrase fields. States that a lost passphrase is \
        unrecoverable, and that the passphrase is stored in the Keychain.
        """
    )
}

extension VaultCreateAccessory {
    private enum Metrics {
        static let fieldWidth: CGFloat = 260
        static let sizeFieldWidth: CGFloat = 72
        static let labelGap: CGFloat = 8
        static let unitGap: CGFloat = 6
        static let rowPitch: CGFloat = 30
        static let fieldHeight: CGFloat = 24
        static let labelHeight: CGFloat = 18
        static let labelRise: CGFloat = 3
        static let errorGap: CGFloat = 8
    }

    /// Where each row sits, bottom-up from the footer.
    private struct Rows {
        let fieldX: CGFloat
        let width: CGFloat
        let height: CGFloat
        let confirm: CGFloat
        let passphrase: CGFloat
        let sizeHint: CGFloat
        let size: CGFloat
        let name: CGFloat

        init(labelWidth: CGFloat, footerHeight: CGFloat, sizeHintHeight: CGFloat) {
            fieldX = labelWidth + Metrics.labelGap
            width = fieldX + Metrics.fieldWidth
            confirm = footerHeight + 12
            passphrase = confirm + Metrics.rowPitch
            sizeHint = passphrase + Metrics.rowPitch + 2
            size = sizeHint + sizeHintHeight + 4
            name = size + Metrics.rowPitch
            height = name + Metrics.fieldHeight
        }

        var captionYs: [CGFloat] {
            [name, size, passphrase, confirm].map { $0 + Metrics.labelRise }
        }
    }

    static func make() -> VaultCreateAccessory {
        let labels = captions().map(label(_:))
        let labelWidth = ceil(labels.map { $0.intrinsicContentSize.width }.reduce(0, max))
        let contentWidth = labelWidth + Metrics.labelGap + Metrics.fieldWidth
        let footer = makeFooter(passphraseNote, width: contentWidth)
        let sizeHint = makeFooter(sizeNote, width: Metrics.fieldWidth)
        let rows = Rows(
            labelWidth: labelWidth,
            footerHeight: footer.frame.height,
            sizeHintHeight: sizeHint.frame.height
        )
        sizeHint.setFrameOrigin(NSPoint(x: labelWidth + Metrics.labelGap, y: rows.sizeHint))
        for (label, y) in zip(labels, rows.captionYs) {
            label.frame = NSRect(x: 0, y: y, width: labelWidth, height: Metrics.labelHeight)
        }

        let nameField = NSTextField(
            frame: NSRect(
                x: rows.fieldX, y: rows.name,
                width: Metrics.fieldWidth, height: Metrics.fieldHeight
            )
        )
        nameField.keepToOneLine()
        nameField.stringValue = defaultName

        let sizeField = NSTextField(
            frame: NSRect(
                x: rows.fieldX, y: rows.size,
                width: Metrics.sizeFieldWidth, height: Metrics.fieldHeight
            )
        )
        sizeField.keepToOneLine()
        sizeField.stringValue = "\(defaultSizeGigabytes)"
        sizeField.alignment = .right
        let unit = sizeUnitLabel(rows: rows)

        let passphraseField = secureField(x: rows.fieldX, y: rows.passphrase)
        let confirmField = secureField(x: rows.fieldX, y: rows.confirm)

        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: rows.width, height: rows.height)
        )
        let controls = [nameField, sizeField, unit, sizeHint, passphraseField, confirmField, footer]
        for subview in labels + controls {
            container.addSubview(subview)
        }

        let errorLabel = NSTextField(wrappingLabelWithString: "")
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = false
        errorLabel.preferredMaxLayoutWidth = rows.width
        errorLabel.frame = NSRect(x: 0, y: 0, width: rows.width, height: 0)
        errorLabel.isHidden = true
        container.addSubview(errorLabel)

        return VaultCreateAccessory(
            view: container,
            nameField: nameField,
            sizeField: sizeField,
            passphraseField: passphraseField,
            confirmField: confirmField,
            errorLabel: errorLabel
        )
    }

    // MARK: - Error row

    /// Say why the vault was not made, under the passphrase note — or, with `nil`, take the row away.
    ///
    /// The row is measured for *this* message in *this* language and the form above it slides up by
    /// exactly that much, the pack sheet's collapse run the other way: an `NSAlert` takes its
    /// accessory's height from the frame, so a label merely unhidden would draw over the note.
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

    // MARK: - Control factories

    private static func captions() -> [String] {
        [
            // Three of these four are shared with the pack sheet — the key is the English text, so
            // they are one catalog entry each, and the comment has to be repeated *verbatim* there
            // because `String(localized:comment:)` takes a `StaticString` (docs/NOTES.md).
            String(
                localized: "Name:",
                comment: "Field label for the name of the thing being created. Pack and New Vault."
            ),
            String(
                localized: "Size:",
                comment: "New Vault sheet field label for the vault's maximum size."
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

    /// The unit, beside the number. **Only** the unit: it sits in a row whose width is fixed by the
    /// column the fields form, so anything longer than a word or two overruns the sheet instead of
    /// wrapping — which is exactly what the first build did, with the explanation attached here and
    /// its last four words drawn outside the sheet in English, before any translation. The sentence
    /// that explanation carried lives in ``sizeNote`` a row below, where its length is free.
    private static func sizeUnitLabel(rows: Rows) -> NSTextField {
        let unit = NSTextField(labelWithString: String(
            localized: "GB",
            comment: """
            Unit beside the New Vault sheet's size field: gigabytes. Keep it to the abbreviation — \
            the field row has no room to grow.
            """
        ))
        unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unit.textColor = .secondaryLabelColor
        unit.sizeToFit()
        unit.frame = NSRect(
            x: rows.fieldX + Metrics.sizeFieldWidth + Metrics.unitGap,
            y: rows.size + Metrics.labelRise,
            width: unit.frame.width,
            height: Metrics.labelHeight
        )
        return unit
    }

    /// Why the number does not have to be chosen carefully — a wrapping row of its own, under the
    /// field, because a ceiling that reads as an allocation is what makes people pick a size too
    /// small to live in.
    static let sizeNote = String(
        localized: "A ceiling, not space taken: the vault only uses what you put in it.",
        comment: "Hint under the New Vault sheet's size field, explaining that the size is a cap."
    )

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    private static func secureField(x: CGFloat, y: CGFloat) -> NSSecureTextField {
        let secure = NSSecureTextField(
            frame: NSRect(x: x, y: y, width: Metrics.fieldWidth, height: Metrics.fieldHeight)
        )
        secure.keepToOneLine()
        secure.placeholderString = String(
            localized: "Required",
            comment: "Placeholder in a passphrase field. Pack sheet and New Vault sheet."
        )
        return secure
    }

    /// A wrapping note, sized for what it holds in *this* language — built with the text already in
    /// it so `sizeThatFits` measures the real thing. Used for both prose rows, since an `NSAlert`
    /// takes its accessory's height from the frame and a wrapping label with no width does not wrap.
    private static func makeFooter(_ text: String, width: CGFloat) -> NSTextField {
        let footer = NSTextField(wrappingLabelWithString: text)
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footer.textColor = .secondaryLabelColor
        footer.isSelectable = false
        footer.preferredMaxLayoutWidth = width
        let fitted = footer.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        footer.frame = NSRect(x: 0, y: 0, width: width, height: ceil(fitted.height))
        return footer
    }
}
