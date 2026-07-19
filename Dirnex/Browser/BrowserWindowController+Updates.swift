import AppKit
import DirnexCore

/// The leading titlebar indicator for a waiting update (PLAN.md §M7 "Sparkle 2 updates").
///
/// Sparkle's own dialog is the only thing that ever says "an update is available", and it is a
/// one-shot: dismiss it and the update is invisible until the next scheduled check hours later. This
/// is the ambient half — an accented download glyph that appears beside the sidebar toggle while
/// `AppUpdater.availability` says something is pending, and clicking it re-opens Sparkle's flow
/// (the same `app.checkForUpdates` command as the App menu item and the ⌘K palette).
///
/// It is hidden, not disabled, when nothing is pending: an always-visible badge would train the eye
/// to ignore it, which is exactly what an update indicator must not do.
extension BrowserWindowController {
    /// Prepare the indicator — behaviour, tight glyph-sized footprint, and state observer. Like the
    /// hidden-files eye it installs no accessory of its own: `installSidebarToggle` places it just
    /// right of the sidebar button in the leading accessory, where a badge that comes and goes
    /// extends the row rightwards into empty title bar instead of moving anything already there.
    func installUpdateIndicator() {
        updateIndicatorButton.bezelStyle = .toolbar
        updateIndicatorButton.isBordered = false
        updateIndicatorButton.imagePosition = .imageOnly
        let image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: "Update available"
        )
        image?.isTemplate = true
        updateIndicatorButton.image = image
        // Accented rather than the cluster's plain template grey: this is the one button in the
        // titlebar that is asking for attention, and it only ever shows when it has something to ask.
        updateIndicatorButton.contentTintColor = .controlAccentColor
        updateIndicatorButton.target = self
        updateIndicatorButton.action = #selector(updateIndicatorPressed(_:))
        updateIndicatorButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateIndicatorButton.heightAnchor.constraint(equalToConstant: 22),
            // Same tight width as the eye and the nav chevrons so the cluster stays evenly spaced.
            updateIndicatorButton.widthAnchor.constraint(equalToConstant: 16)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAvailabilityChanged),
            name: AppUpdater.availabilityDidChange,
            object: nil
        )
        updateUpdateIndicator()
    }

    @objc private func updateAvailabilityChanged() {
        updateUpdateIndicator()
    }

    /// Show or hide the glyph against the current availability, and point its tooltip at the version
    /// Sparkle found. Hiding is what collapses it out of the stack view (`NSStackView` detaches
    /// hidden arranged subviews), so no gap is left behind.
    private func updateUpdateIndicator() {
        let availability = (NSApp.delegate as? AppDelegate)?.updateAvailability ?? .none
        updateIndicatorButton.isHidden = !availability.isAvailable
        updateIndicatorButton.toolTip = availability.tooltip
    }

    /// Dispatch through the responder chain to `AppDelegate.checkForUpdates` — the same path the App
    /// menu item and the palette command take, so the click lands in Sparkle's normal user-initiated
    /// flow (which re-finds the pending update and offers to install it) rather than a private one.
    @objc private func updateIndicatorPressed(_ sender: NSButton) {
        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: sender)
    }
}
