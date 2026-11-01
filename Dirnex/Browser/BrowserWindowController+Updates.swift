import AppKit
import DirnexCore

/// The titlebar indicator for a waiting update (PLAN.md §M7 "Sparkle 2 updates").
///
/// Sparkle's own dialog is the only thing that ever says "an update is available", and it is a
/// one-shot: dismiss it and the update is invisible until the next scheduled check hours later. This
/// is the ambient half — an accented download glyph that appears in the window's top right corner
/// while `AppUpdater.availability` says something is pending, and clicking it re-opens Sparkle's flow
/// (the same `app.checkForUpdates` command as the App menu item and the ⌘K palette).
///
/// It is hidden, not disabled, when nothing is pending: an always-visible badge would train the eye
/// to ignore it, which is exactly what an update indicator must not do.
extension BrowserWindowController {
    /// How far the glyph's cell stays in from the window's right edge, which clears the 7 pt of it
    /// that `NSThemeFrame` keeps for its resize border. The license label ends as far from the edge
    /// when it stands there alone.
    private static let indicatorTrailingInset: CGFloat = 8
    private static let indicatorWidth: CGFloat = 16

    /// Install the indicator — behavior, tight glyph-sized footprint, state observer, and a trailing
    /// accessory of its own, which takes no room while nothing is waiting (`updateUpdateIndicator`).
    func installUpdateIndicator() {
        updateIndicatorButton.bezelStyle = .toolbar
        updateIndicatorButton.isBordered = false
        updateIndicatorButton.imagePosition = .imageOnly
        let image = NSImage(
            systemSymbolName: "arrow.down.circle.fill",
            accessibilityDescription: String(
                localized: "Update available",
                comment: "Accessibility label for the titlebar update indicator."
            )
        )
        image?.isTemplate = true
        updateIndicatorButton.image = image
        // Accented rather than the cluster's plain template gray: this is the one button in the
        // titlebar that is asking for attention, and it only ever shows when it has something to ask.
        // The user's accent, `.controlAccentColor` untouched (PLAN.md §M15 Slice 2).
        updateIndicatorButton.contentTintColor = AppPreferences.shared.palette.resolvedAccent
        updateIndicatorButton.target = self
        updateIndicatorButton.action = #selector(updateIndicatorPressed(_:))
        updateIndicatorButton.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        container.addSubview(updateIndicatorButton)
        NSLayoutConstraint.activate([
            updateIndicatorButton.heightAnchor.constraint(equalToConstant: 22),
            updateIndicatorButton.widthAnchor.constraint(equalToConstant: Self.indicatorWidth),
            updateIndicatorButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            updateIndicatorButton.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Self.indicatorTrailingInset
            )
        ])
        updateIndicatorAccessory.view = container
        updateIndicatorAccessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(updateIndicatorAccessory)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateAvailabilityChanged),
            name: AppUpdater.availabilityDidChange,
            object: nil
        )
        // The indicator's tint is set once here rather than on every state change, so a live accent
        // change has to reach it separately — it is the one accent site that is not redrawn by the
        // pane's own refresh.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIndicatorPaletteChanged),
            name: AppPreferences.paletteDidChange,
            object: nil
        )
        updateUpdateIndicator()
    }

    @objc private func updateAvailabilityChanged() {
        updateUpdateIndicator()
    }

    @objc private func updateIndicatorPaletteChanged() {
        updateIndicatorButton.contentTintColor = AppPreferences.shared.palette.resolvedAccent
    }

    /// Show or hide the glyph against the current availability, and point its tooltip at the version
    /// Sparkle found. Hidden, it collapses its accessory to no width, so no gap is left behind and
    /// the tab strip beside it gets the room back.
    private func updateUpdateIndicator() {
        let availability = (NSApp.delegate as? AppDelegate)?.updateAvailability ?? .none
        updateIndicatorButton.isHidden = !availability.isAvailable
        updateIndicatorButton.toolTip = Self.tooltip(for: availability)
        let view = updateIndicatorAccessory.view
        let width = availability.isAvailable ? Self.indicatorWidth + Self.indicatorTrailingInset : 0
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        tabStripsNeedLayout()
    }

    /// The indicator's tooltip. Names the version when the appcast gave one, since "1.3.0 is
    /// available" is the one thing a user hovering the button wants to know that the glyph can't say.
    ///
    /// The words are the app's, not `UpdateAvailability`'s — the core owns the *state* and ships no
    /// resources, so a sentence composed there is English forever on a permanently visible control
    /// (PLAN.md §M12 Slice 11). Internal so `UpdateIndicatorTooltipTests` can drive it directly.
    static func tooltip(for availability: UpdateAvailability) -> String {
        guard availability.isAvailable else {
            return String(
                localized: "Check for updates",
                comment: "Titlebar update indicator tooltip when nothing is pending."
            )
        }
        guard let pendingVersion = availability.pendingVersion else {
            return String(
                localized: "An update is available — click to install",
                comment: "Titlebar update indicator tooltip when the appcast named no version."
            )
        }
        return String(
            localized: "Dirnex \(pendingVersion) is available — click to install",
            comment: "Titlebar update indicator tooltip; %@ is the pending version."
        )
    }

    /// Dispatch through the responder chain to `AppDelegate.checkForUpdates` — the same path the App
    /// menu item and the palette command take, so the click lands in Sparkle's normal user-initiated
    /// flow (which re-finds the pending update and offers to install it) rather than a private one.
    @objc private func updateIndicatorPressed(_ sender: NSButton) {
        NSApp.sendAction(#selector(AppDelegate.checkForUpdates(_:)), to: nil, from: sender)
    }
}
