import Combine
import SwiftUI

/// The Settings window's tabs, so a command can open the window on one of them.
enum SettingsTab: Hashable {
    case general
    case panels
    case operations
    case shortcuts
    case license
}

/// Which tab the Settings window shows. Shared, so `SettingsWindowController.present(tab:)` can
/// switch it while the window is already open.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var tab: SettingsTab = .general
}

/// The root of the Settings window (PLAN.md §M3 "Settings window (SwiftUI): general, panels,
/// operations, shortcuts"). A tabbed container over the preference panes; each observes a
/// shared store so an edit persists and the rest of the app reflects it immediately.
///
/// The License tab (PLAN.md §M29) exists only in a build that shows licensing at all
/// (`LicensingSwitch`).
struct SettingsView: View {
    @ObservedObject var keyBindings: KeyBindingStore
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var language: LanguageSettings = .shared
    @ObservedObject var navigation: SettingsNavigation = .shared
    var showsLicense: Bool = LicensingSwitch.isOn

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsView(preferences: preferences, language: language)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            PanelsSettingsView(preferences: preferences)
                .tabItem { Label("Panels", systemImage: "sidebar.squares.left") }
                .tag(SettingsTab.panels)

            OperationsSettingsView(preferences: preferences)
                .tabItem { Label("Operations", systemImage: "arrow.left.arrow.right") }
                .tag(SettingsTab.operations)

            ShortcutsSettingsView(store: keyBindings)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)

            if showsLicense {
                LicenseSettingsView(store: .shared)
                    .tabItem { Label("License", systemImage: "checkmark.seal") }
                    .tag(SettingsTab.license)
            }
        }
        .frame(width: 600, height: 460)
    }
}
