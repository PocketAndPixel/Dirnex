import Combine
import DirnexCore
import Foundation

/// App-wide persistence for the user's rebindable keyboard shortcuts (PLAN.md §M3
/// "rebindable shortcuts"). Wraps the headless `KeyBindings` value type, persists it as boring
/// JSON in `UserDefaults` (matching `FavoritesStore`/`FrecencyStore`/`TabPersistence`), and
/// publishes changes so the menu bar and the Settings UI both refresh when a binding changes.
///
/// One shared instance is the single writer: `MainMenuBuilder` reads it when building the menu,
/// the Cmd+K palette reads it to display effective shortcuts, and the Settings window's
/// `@ObservedObject` binding drives the shortcut editor. A rebind reassigns `bindings`
/// (firing `objectWillChange`) *and* posts `didChange` so `AppDelegate` can rebuild the menu —
/// key equivalents only take effect once the menu is regenerated.
@MainActor
final class KeyBindingStore: ObservableObject {
    static let shared = KeyBindingStore()

    /// Posted after a binding change is applied and persisted, so non-SwiftUI observers
    /// (the app delegate) can rebuild the registry-driven main menu.
    static let didChange = Notification.Name("Dirnex.keyBindingsDidChange")

    @Published private(set) var bindings: KeyBindings

    private let defaults: UserDefaults
    private let key = "Dirnex.keyBindings"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(KeyBindings.self, from: data) {
            bindings = decoded
        } else {
            bindings = KeyBindings()
        }
    }

    // MARK: - Reads

    /// The effective shortcut for `id` — the user's override or the catalog default. The menu
    /// builder and palette call this instead of reading `Command.shortcut` directly.
    func shortcut(for id: String) -> CommandShortcut? {
        bindings.shortcut(for: id)
    }

    // MARK: - Writes

    /// Rebind `id` to `shortcut` (or unbind it with `nil`), persist, and notify.
    func setShortcut(_ shortcut: CommandShortcut?, for id: String) {
        var updated = bindings
        updated.setShortcut(shortcut, for: id)
        apply(updated)
    }

    /// Revert `id` to its catalog default.
    func reset(_ id: String) {
        var updated = bindings
        updated.reset(id)
        apply(updated)
    }

    /// Clear every customization, restoring the shipped defaults.
    func resetAll() {
        apply(KeyBindings())
    }

    /// Replace the whole scheme with a built-in preset.
    func apply(preset: KeyBindings.Preset) {
        apply(KeyBindings.preset(preset))
    }

    private func apply(_ updated: KeyBindings) {
        guard updated != bindings else { return }
        bindings = updated
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        defaults.set(data, forKey: key)
    }
}
