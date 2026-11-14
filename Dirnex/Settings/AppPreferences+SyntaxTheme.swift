import Foundation

/// The syntax theme's bookkeeping (PLAN.md §M39 ▸ Slice 10), out of `AppPreferences` for its length
/// ceiling, as the palette's is: the stored property stays in the class, as stored properties must.
extension AppPreferences {
    /// Posted (on the main actor) when the syntax theme changes. `SyntaxThemeRepaint` listens to the
    /// shared instance's, and redraws every window in the new colors.
    static let syntaxThemeDidChange = Notification.Name("Dirnex.syntaxThemeDidChange")

    func syntaxThemeChanged(from old: SyntaxColorTheme) {
        guard syntaxTheme != old else { return }
        defaults.set(syntaxTheme.rawValue, forKey: Keys.syntaxTheme)
        // Before the post, so whatever redraws on it draws in the new colors. Compared by identity
        // rather than by domain: `shared` is the instance the Settings window binds to.
        if self === Self.shared {
            SyntaxTheme.select(syntaxTheme)
        }
        NotificationCenter.default.post(name: Self.syntaxThemeDidChange, object: self)
    }
}
