import SwiftUI

/// The root of the Settings window (PLAN.md §M3 "Settings window (SwiftUI): general, panels,
/// operations, shortcuts"). A tabbed container over the four preference panes; each observes a
/// shared store so an edit persists and the rest of the app reflects it immediately.
struct SettingsView: View {
    @ObservedObject var keyBindings: KeyBindingStore
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        TabView {
            GeneralSettingsView(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }

            PanelsSettingsView(preferences: preferences)
                .tabItem { Label("Panels", systemImage: "sidebar.squares.left") }

            OperationsSettingsView(preferences: preferences)
                .tabItem { Label("Operations", systemImage: "arrow.left.arrow.right") }

            ShortcutsSettingsView(store: keyBindings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 600, height: 460)
    }
}
