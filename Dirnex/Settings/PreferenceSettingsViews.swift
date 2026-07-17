import SwiftUI

/// The General / Panels / Operations tabs of the Settings window (PLAN.md §M3). Each edits an
/// `AppPreferences` toggle that a single point in the browser reads; the Shortcuts tab lives in
/// its own file. Grouped `Form`s give the native macOS Settings look.

struct GeneralSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Reopen tabs from the previous session", isOn: $preferences.restoreSession)
            } footer: {
                Text("When off, each new window starts at your Home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PanelsSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Show hidden files", isOn: $preferences.showHidden)
            } footer: {
                Text(
                    "Reveals dotfiles like .git and .env in every pane. Also on the toolbar and ⇧⌘."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show Finder tags", isOn: $preferences.showTags)
            } footer: {
                Text(
                    "Shows each file's tag colours at the right edge of its name, as Finder does. "
                        + "Also in the View menu. Archives and remote volumes have no tags, so "
                        + "nothing is drawn there."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show cloud sync status", isOn: $preferences.showSyncStatus)
            } footer: {
                Text(
                    "Badges a file whose bytes are still in iCloud (or another provider), on their "
                        + "way up or down, or in conflict — at the right edge of its name, as "
                        + "Finder does. Folders outside a cloud provider are never scanned, and "
                        + "fully synced files show nothing. Also in the View menu."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show function key bar", isOn: $preferences.showFunctionBar)
            } footer: {
                Text(
                    "A row of F-key buttons along the window bottom — Rename, View, Copy, Move, "
                        + "New Folder, Delete — the Total Commander function bar. Also in the View "
                        + "menu; the keys work whether or not the bar is shown."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Switch focus to folders opened from search results",
                    isOn: $preferences.focusOpenedSearchDirectory
                )
            } footer: {
                Text(
                    "Opening a folder from a search tab leaves the results in place and opens it in "
                        + "the other pane. When off, focus stays on the results so you can keep "
                        + "opening more."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct OperationsSettingsView: View {
    @ObservedObject var preferences: AppPreferences

    var body: some View {
        Form {
            Section {
                Toggle("Ask before moving items to the Trash", isOn: $preferences.confirmTrash)
            } footer: {
                Text("Permanent delete always asks for confirmation, regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
