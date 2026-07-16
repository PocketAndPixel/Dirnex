import AppKit
import DirnexCore

/// The trailing titlebar button that shows or hides hidden (dot) files across the whole app —
/// the same effect as ⇧⌘. or View ▸ Show Hidden Files, in reach of the mouse. It only drives
/// `AppPreferences.showHidden`; the panes re-filter themselves off `showHiddenDidChange`, which
/// also restyles the button so its eye/eye-slash glyph always tracks the current state.
extension BrowserWindowController {
    /// Prepare the eye button — behaviour, tight glyph-sized footprint, and state observer. It has
    /// no accessory of its own: `installNavigationButtons` places it as the leading member of the
    /// shared trailing control cluster (eye · Back · Forward), so all three read as one evenly
    /// spaced panel. Restyled immediately to the current state, and again on every
    /// `showHiddenDidChange`.
    func installHiddenToggle() {
        hiddenToggleButton.bezelStyle = .toolbar
        hiddenToggleButton.isBordered = false
        hiddenToggleButton.imagePosition = .imageOnly
        hiddenToggleButton.target = self
        hiddenToggleButton.action = #selector(toggleHiddenFilesFromButton)
        hiddenToggleButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hiddenToggleButton.heightAnchor.constraint(equalToConstant: 22),
            // Same tight width as the nav chevrons so the cluster's spacing is uniform.
            hiddenToggleButton.widthAnchor.constraint(equalToConstant: 16)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hiddenStateChanged),
            name: AppPreferences.showHiddenDidChange,
            object: nil
        )
        updateHiddenToggleButton()
    }

    @objc private func toggleHiddenFilesFromButton() {
        AppPreferences.shared.toggleShowHidden()
    }

    @objc private func hiddenStateChanged() {
        updateHiddenToggleButton()
    }

    /// Point the glyph at the current state: an accented open eye when hidden files are showing,
    /// a plain eye-slash when they're not. The tooltip names the action and its shortcut.
    private func updateHiddenToggleButton() {
        let showing = AppPreferences.shared.showHidden
        let symbol = showing ? "eye" : "eye.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Show hidden files")
        image?.isTemplate = true
        hiddenToggleButton.image = image
        hiddenToggleButton.contentTintColor = showing ? .controlAccentColor : nil

        let action = showing ? "Hide hidden files" : "Show hidden files"
        if let hint = KeyBindingStore.shared.shortcut(for: "view.toggleHidden")?.display {
            hiddenToggleButton.toolTip = "\(action) (\(hint))"
        } else {
            hiddenToggleButton.toolTip = action
        }
    }
}
