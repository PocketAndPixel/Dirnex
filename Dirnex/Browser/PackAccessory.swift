import AppKit
import DirnexCore

/// The pack sheet's accessory controls, and the one piece of behaviour between them: the format
/// popup drives whether the compression popup is enabled, because `.tar` has no compression to
/// level (`ArchivePacking.Format.supportsCompressionLevel`).
///
/// An object rather than a struct because it is the popup's target/action, and it reads the two
/// popups back as core values so the sheet's completion handler never touches an index. Kept alive
/// by the completion closure that captures it — `NSControl.target` is weak, so the accessory would
/// otherwise be gone by the time the user changes the format.
final class PackAccessory: NSObject {
    let view: NSView
    let nameField: NSTextField
    let formatPopup: NSPopUpButton
    let levelPopup: NSPopUpButton
    private let levelLabel: NSTextField

    init(
        view: NSView,
        nameField: NSTextField,
        formatPopup: NSPopUpButton,
        levelPopup: NSPopUpButton,
        levelLabel: NSTextField
    ) {
        self.view = view
        self.nameField = nameField
        self.formatPopup = formatPopup
        self.levelPopup = levelPopup
        self.levelLabel = levelLabel
        super.init()
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        syncLevelEnabled()
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

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        syncLevelEnabled()
    }

    /// Grey the compression row out for a format that compresses nothing, rather than leaving a
    /// live control whose setting is silently dropped. The label is dimmed by hand: an
    /// `NSTextField` label is not a subview of the popup and so does not inherit its enabled
    /// state, which leaves a fully-lit caption over a greyed control unless it is set here.
    private func syncLevelEnabled() {
        let enabled = format.supportsCompressionLevel
        levelPopup.isEnabled = enabled
        levelLabel.textColor = enabled ? .labelColor : .disabledControlTextColor
    }
}
