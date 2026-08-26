import DirnexCore
import Foundation

/// The three colors the user owns, resolved and published (PLAN.md §M15 Slice 2).
///
/// Split out of `AppPreferences` when the remote-refresh floor took that file past SwiftLint's
/// 500-line ceiling, along the seam the concept already had: the *storage* is three `@Published`
/// hex strings and has to stay in the class, as stored properties must, while everything that turns
/// them into a `PanelPalette` and tells the app they moved is this — the same shape as
/// `PanelPalette` and `PaletteSettingsSection`, which are already the palette's other two files.
extension AppPreferences {
    /// The three, resolved. Read at each drawing site — cheap (three dictionary lookups' worth of
    /// stored string parsing) and always current, so no view has to be told twice.
    var palette: PanelPalette {
        PanelPalette(
            accent: PanelPalette.color(fromHex: accentColorHex),
            cursor: PanelPalette.color(fromHex: cursorColorHex),
            mark: PanelPalette.color(fromHex: markColorHex)
        )
    }

    /// Posted (on the main actor) when any of the three colors changes, so every open pane, tab
    /// strip, path bar and titlebar indicator restyles live. One notification for all three rather
    /// than three: every observer repaints the same surfaces regardless of which color moved, and
    /// splitting them would only invite a site that listens for two of the three.
    static let paletteDidChange = Notification.Name("Dirnex.paletteDidChange")

    func paletteValueChanged(_ new: String, _ old: String, key: String) {
        guard new != old else { return }
        defaults.set(new, forKey: key)
        guard !isResettingPalette else { return }
        NotificationCenter.default.post(name: Self.paletteDidChange, object: self)
    }

    /// Put all three back to Follow System in one step, for the Settings button that offers it —
    /// the one gesture that restores the shipped rendering exactly, without the user having to
    /// remember which of the three they had touched.
    func resetPalette() {
        guard !palette.isFollowingSystem else { return }
        isResettingPalette = true
        accentColorHex = ""
        cursorColorHex = ""
        markColorHex = ""
        isResettingPalette = false
        NotificationCenter.default.post(name: Self.paletteDidChange, object: self)
    }
}
