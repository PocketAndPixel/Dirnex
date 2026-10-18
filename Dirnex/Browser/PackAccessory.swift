import AppKit
import DirnexCore

/// The pack sheet's accessory controls, and the behavior between them.
///
/// Three rules, each a fact about the formats rather than a style choice:
/// - the format popup drives whether the **compression** popup is enabled, because `.tar` has no
///   compression to level (`ArchivePacking.Format.supportsCompressionLevel`);
/// - the format popup drives whether the **encryption** popup is enabled, because zip is the only
///   container that can be encrypted at all — libarchive's 7-Zip writer refuses the option and tar
///   has no notion of it (`ArchiveEncryption`);
/// - the encryption popup drives whether the two passphrase rows, the "Hide file names" checkbox and
///   the footer note are on screen **at all**, because none of them means anything without a cipher.
///
/// The last of those is a *collapse*, and it took measuring to be sure it was affordable. An
/// `NSAlert` reserves vertical space for its accessory from that view's **frame** (docs/NOTES.md), so
/// a form that grows and shrinks under a popup needs the alert re-laid out around it mid-sheet —
/// which is why these rows started out merely grayed. Probed on a live sheet: `NSAlert.layout()`
/// does exactly that, synchronously, and the sheet re-fits to the pixel (content 438 → 288 pt for a
/// 150 pt accessory) while staying centered on its parent, so nothing jumps. The height change is
/// therefore one call, handed to the presenter through ``onHeightChange`` — the accessory owns the
/// arithmetic, the sheet owns the alert.
///
/// **The sheet stays up until the passphrases pass**, the New Vault sheet's rule. An empty or
/// mismatched pair is said in ``errorLabel`` under the form, with the name, format and level the
/// user chose still in place. ``routePack(through:)`` is what makes that possible on an `NSAlert`,
/// which otherwise ends its sheet on every button press before anything has been checked. The error
/// row and the collapse are independent translations — the row lifts every control off the floor,
/// the collapse drops only what sits above the passphrase block — so they commute, and a collapse
/// clears the error first because it is about rows that are no longer on screen.
///
/// An object rather than a struct because it is the popups' and the Pack button's target, and it
/// reads every control back as a core value so the presenter never touches an index. Kept alive by
/// the completion closure that captures it — `NSControl.target` is weak, so the accessory would
/// otherwise be gone by the time the user changes anything.
///
/// Main-actor isolated, like every control it holds. Its nested value types (`Defaults`,
/// `EncryptionRows`) are not, since isolation does not reach a nested type.
@MainActor
final class PackAccessory: NSObject {
    /// The rows that exist only while a cipher is chosen, and what putting them away costs.
    ///
    /// `delta` is the y the encryption popup sits at in the built (expanded) layout — which is
    /// exactly the height everything below it occupies — so a collapse is "hide those, slide these
    /// down by `delta`, lose `delta` of height", and an expansion is the same in reverse.
    struct EncryptionRows {
        /// Hidden outright when there is no cipher: both passphrase captions and their fields, the
        /// "Hide file names" checkbox, and the footer note.
        let hidden: [NSView]
        /// Everything above the passphrase block, which slides down onto the new floor.
        let shifted: [NSView]
        let delta: CGFloat
    }

    let view: NSView
    let nameField: NSTextField
    let formatPopup: NSPopUpButton
    let levelPopup: NSPopUpButton
    let encryptionPopup: NSPopUpButton
    let passphraseField: NSSecureTextField
    let confirmField: NSSecureTextField
    let hideNamesCheckbox: NSButton
    /// Why the last Pack did not start, at the bottom of the form. Hidden and taking no height until
    /// there is something to say (``showError(_:)``).
    let errorLabel: NSTextField

    /// Called after ``view``'s frame changes, for the presenter to re-lay out the alert around it.
    /// Left `nil` while the sheet is being built: the initializer collapses a no-cipher form before
    /// the alert has ever measured it, so there is nothing to re-lay out yet.
    var onHeightChange: (() -> Void)?

    /// What pressing Pack does, once ``routePack(through:)`` has taken the button over.
    var onPack: (() -> Void)?

    private let levelLabel: NSTextField
    private let encryptionRows: EncryptionRows
    /// The built layout is the expanded one; `init` collapses it if the defaults carry no cipher.
    private var showingEncryptionRows = true
    /// The height the error row adds, gap included; zero while it is hidden.
    private var errorRowHeight: CGFloat = 0

    init(
        view: NSView,
        nameField: NSTextField,
        formatPopup: NSPopUpButton,
        levelPopup: NSPopUpButton,
        levelLabel: NSTextField,
        encryptionPopup: NSPopUpButton,
        passphraseField: NSSecureTextField,
        confirmField: NSSecureTextField,
        hideNamesCheckbox: NSButton,
        errorLabel: NSTextField,
        encryptionRows: EncryptionRows
    ) {
        self.view = view
        self.nameField = nameField
        self.formatPopup = formatPopup
        self.levelPopup = levelPopup
        self.levelLabel = levelLabel
        self.encryptionPopup = encryptionPopup
        self.passphraseField = passphraseField
        self.confirmField = confirmField
        self.hideNamesCheckbox = hideNamesCheckbox
        self.errorLabel = errorLabel
        self.encryptionRows = encryptionRows
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        encryptionPopup.target = self
        encryptionPopup.action = #selector(encryptionChanged)
        syncLevelEnabled()
        syncEncryptionEnabled()
    }

    /// Make `button` — the alert's Pack — run ``onPack`` instead of ending the sheet.
    ///
    /// A click, Return and keypad Enter all reach the button through `performClick`, the
    /// `AlertKeyCatcher` included, so retargeting it covers every way of pressing it (docs/NOTES.md
    /// ▸ Alerts, sheets and dialogs).
    func routePack(through button: NSButton) {
        button.target = self
        button.action = #selector(packPressed)
    }

    @objc private func packPressed(_ sender: Any?) {
        onPack?()
    }

    /// The chosen container format. The popup is built from `Format.allCases` in order, so the
    /// selected index maps straight back; a negative index (no selection) falls back to the first.
    var format: ArchivePacking.Format {
        ArchivePacking.Format.allCases[max(0, formatPopup.indexOfSelectedItem)]
    }

    /// The chosen compression level — `.normal` whenever the format has no compression to level,
    /// so a stale selection left over from a compressing format can't be read back for `.tar`.
    var level: ArchivePacking.CompressionLevel {
        guard format.supportsCompressionLevel else { return .normal }
        return ArchivePacking.CompressionLevel.allCases[max(0, levelPopup.indexOfSelectedItem)]
    }

    /// The chosen cipher — `.none` for any format that cannot carry one, so a selection left over
    /// from zip can't be read back for a tarball and silently dropped by the writer.
    var encryption: ArchiveEncryption {
        guard format == .zip else { return .none }
        return ArchiveEncryption.allCases[max(0, encryptionPopup.indexOfSelectedItem)]
    }

    /// Whether to wrap the payload so the zip's permanently-plaintext central directory lists one
    /// entry. Meaningless without a cipher, and read as `.visible` there for the same reason `level`
    /// is read as `.normal` for `.tar`.
    var namePrivacy: ArchiveNamePrivacy {
        guard encryption.isEncrypted, hideNamesCheckbox.state == .on else { return .visible }
        return .hidden
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        syncLevelEnabled()
        syncEncryptionEnabled()
    }

    @objc private func encryptionChanged(_ sender: NSPopUpButton) {
        syncEncryptionEnabled()
    }

    /// Gray the compression row out for a format that compresses nothing, rather than leaving a
    /// live control whose setting is silently dropped. The label is dimmed by hand: an
    /// `NSTextField` label is not a subview of the popup and so does not inherit its enabled
    /// state, which leaves a fully-lit caption over a grayed control unless it is set here.
    private func syncLevelEnabled() {
        let enabled = format.supportsCompressionLevel
        levelPopup.isEnabled = enabled
        levelLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
    }

    /// Follow the format into the encryption row, and the encryption row into everything below it.
    ///
    /// Moving away from zip **resets the popup to None** rather than merely disabling it, so what
    /// the sheet shows is what it will do: a grayed "AES-256" over a `.tar.gz` reads as a promise
    /// the writer cannot keep. `encryption` refuses it either way, and this is what stops the two
    /// answers disagreeing on screen.
    ///
    /// The encryption popup itself is *disabled* rather than hidden for a format that cannot carry a
    /// cipher — it is the answer to "can I encrypt this?", which a user asks by looking for the row.
    /// Only what a cipher would *configure* goes away.
    private func syncEncryptionEnabled() {
        let canEncrypt = format == .zip
        encryptionPopup.isEnabled = canEncrypt
        if !canEncrypt {
            encryptionPopup.selectItem(at: 0)
        }
        setEncryptionRowsVisible(encryption.isEncrypted)
    }

    /// Put the passphrase block on screen, or take it away, and resize the accessory to match.
    ///
    /// Guarded on the current state so a format change that leaves the cipher alone — every one of
    /// them but the move off zip — costs no relayout at all.
    private func setEncryptionRowsVisible(_ visible: Bool) {
        guard visible != showingEncryptionRows else { return }
        showingEncryptionRows = visible
        if !visible {
            // Every error this sheet can show is about a passphrase, and those rows are going.
            // Folded into this one relayout rather than reported as a second.
            resizeErrorRow(for: nil)
        }
        let shift = visible ? encryptionRows.delta : -encryptionRows.delta
        for row in encryptionRows.hidden {
            row.isHidden = !visible
        }
        for row in encryptionRows.shifted {
            row.frame.origin.y += shift
        }
        view.frame.size.height += shift
        onHeightChange?()
    }

    /// Say why the pack did not start, under the footer note — or, with `nil`, take the row away.
    ///
    /// The row is measured for *this* message in *this* language and the form above it slides up by
    /// exactly that much — the collapse run the other way, and for the same reason: an `NSAlert`
    /// takes its accessory's height from the frame, so a label merely unhidden would draw over the
    /// note.
    func showError(_ message: String?) {
        guard resizeErrorRow(for: message) else { return }
        onHeightChange?()
    }

    /// Put `message` in the error row and move everything else by the height that changed, without
    /// telling the presenter. Returns whether the accessory's height changed.
    ///
    /// **Every other subview moves, the hidden passphrase block included**, so the block keeps its
    /// place relative to the floor while it is collapsed and comes back exactly above the row. Both
    /// this and the collapse are plain translations, so the order they run in does not matter.
    @discardableResult
    private func resizeErrorRow(for message: String?) -> Bool {
        let text = message ?? ""
        errorLabel.stringValue = text
        errorLabel.isHidden = text.isEmpty
        let width = view.frame.width
        let labelHeight = text.isEmpty
            ? 0
            : ceil(errorLabel.sizeThatFits(
                NSSize(width: width, height: .greatestFiniteMagnitude)
            ).height)
        let rowHeight = text.isEmpty ? 0 : labelHeight + Self.errorGap
        errorLabel.frame = NSRect(x: 0, y: 0, width: width, height: labelHeight)
        let shift = rowHeight - errorRowHeight
        guard shift != 0 else { return false }
        errorRowHeight = rowHeight
        for subview in view.subviews where subview !== errorLabel {
            subview.frame.origin.y += shift
        }
        view.frame.size.height += shift
        return true
    }

    /// The space between the error row and the lowest control above it.
    private static let errorGap: CGFloat = 8

    /// The two things a user must know *before* typing a passphrase, in the order they matter.
    ///
    /// PLAN.md §6 makes this wording a milestone deliverable rather than a detail: a forgotten
    /// passphrase is the only failure in Dirnex that is silent, total and permanent — no undo
    /// journal, no Trash, no support call — so the sheet says so plainly instead of leaving the user
    /// to infer it. The compatibility sentence is second and is measured fact: macOS's own `unzip`
    /// reports `unsupported compression method 99` and Archive Utility `Unknown compression type`,
    /// and Windows Explorer's built-in zip cannot read it either.
    /// Internal because the layout has to *measure* it: the footer is built holding this text so its
    /// height is the real one, then hidden with the rest of the block until a cipher is chosen.
    static let encryptionNote = String(
        localized: """
        If you forget this passphrase the files are gone — there is no way to recover them. \
        Opening the archive needs Keka, 7-Zip or WinRAR; the Finder and Windows Explorer can’t \
        read AES-256 zips.
        """,
        comment: """
        Note under the pack sheet's encryption controls, shown only when a cipher is chosen. \
        States that a lost passphrase is unrecoverable and which apps can open the archive.
        """
    )
}
