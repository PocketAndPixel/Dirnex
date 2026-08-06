import DirnexCore
import SwiftUI

/// The General / Panels / Operations tabs of the Settings window (PLAN.md §M3). Each edits an
/// `AppPreferences` toggle that a single point in the browser reads; the Shortcuts tab lives in
/// its own file. Grouped `Form`s give the native macOS Settings look.

struct GeneralSettingsView: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var language: LanguageSettings

    var body: some View {
        Form {
            LanguageSettingsSection(settings: language)

            Section {
                Toggle("Reopen tabs from the previous session", isOn: $preferences.restoreSession)
            } footer: {
                Text("When off, each new window starts at your Home folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Receive beta updates", isOn: $preferences.receiveBetaUpdates)
            } footer: {
                Text(
                    """
                    Also offers pre-release builds when Dirnex checks for updates. Betas are newer but less \
                    tested; you're moved back onto a stable release automatically once one catches up.
                    """
                )
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
                Picker("Row height", selection: $preferences.rowDensity) {
                    ForEach(RowDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    """
                    How much vertical room each file row gets, in every pane and tab. Compact fits \
                    more on screen; Roomy is easier to aim at. The icons follow along.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Size visualization", selection: $preferences.sizeVizDisplayMode) {
                    ForEach(SizeVizDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(
                    """
                    What the size-bar column shows when a pane is in Size Visualization (View menu): \
                    the ncdu-style bar, each row’s share of the folder as a percentage, or both.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Run JavaScript in rendered HTML previews",
                    isOn: $preferences.quickViewJavaScriptEnabled
                )
            } footer: {
                Text(
                    """
                    A Quick View set to show a page (2) renders it in place, and a self-contained \
                    report usually needs its own scripts to draw charts or formulas. Previews never \
                    reach the network whatever this says — every request to anything but the file \
                    itself is blocked — so a script can only change what you see. It is off by \
                    default, because a preview renders as the cursor moves: turn it on when a page \
                    needs its scripts.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            PaletteSettingsSection(preferences: preferences)

            FileColorRulesSection()

            Section {
                Toggle(
                    "Switch focus to folders opened from search results",
                    isOn: $preferences.focusOpenedSearchDirectory
                )
            } footer: {
                Text(
                    """
                    Opening a folder from a search tab leaves the results in place and opens it in the other \
                    pane. When off, focus stays on the results so you can keep opening more.
                    """
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

    /// Probed once per appearance of the tab, not per redraw: it stats a handful of paths, and the
    /// set of installed apps does not change while a settings pane is open.
    @State private var installedDiffTools: [ExternalDiffTool] = []
    /// Probed with the diff tools, and for the same reason — a handful of LaunchServices lookups.
    @State private var installedEditors: [ExternalTextEditor] = []
    /// What "Automatic" resolves to right now, so the footer can name it rather than leaving the
    /// default choice as the one the user can't see.
    @State private var automaticEditorName: String?

    var body: some View {
        Form {
            Section {
                Toggle("Ask before moving items to the Trash", isOn: $preferences.confirmTrash)
            } footer: {
                Text("Permanent delete always asks for confirmation, regardless of this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Compare files with", selection: $preferences.diffToolIdentifier) {
                    Text("Automatic").tag("")
                    if !installedDiffTools.isEmpty {
                        Divider()
                        ForEach(installedDiffTools) { tool in
                            Text(tool.displayName).tag(tool.identifier)
                        }
                    }
                }
                .disabled(installedDiffTools.isEmpty)
            } footer: {
                Text(diffToolFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Edit files with", selection: $preferences.textEditorIdentifier) {
                    Text(automaticEditorLabel).tag("")
                    if !installedEditors.isEmpty {
                        Divider()
                        ForEach(installedEditors) { editor in
                            Text(editor.displayName).tag(editor.identifier)
                        }
                    }
                }
            } footer: {
                Text(
                    """
                    The editor F4 opens the file under the cursor in. ⇧F4 names a new file first, creating it if \
                    it doesn’t exist yet.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            installedDiffTools = ExternalDiffLauncher.installedTools()
            installedEditors = ExternalTextEditorLauncher.installedEditors()
            automaticEditorName = ExternalTextEditorLauncher.automaticEditor()?.displayName
        }
    }

    /// "Automatic (TextEdit)" — the system's plain-text handler, named. Without the name the
    /// default choice is the one thing in the picker that doesn't say what it does.
    private var automaticEditorLabel: String {
        guard let name = automaticEditorName else { return String(localized: "Automatic") }
        return String(localized: "Automatic (\(name))")
    }

    /// Says which tool Compare By Contents will actually open — including the case that needs it
    /// most, where the user has installed none and the command is greyed out with no explanation.
    private var diffToolFooter: String {
        guard !installedDiffTools.isEmpty else {
            return String(localized: """
            Compare By Contents (⌥F3) needs a diff tool. Install FileMerge (part of Xcode), \
            Kaleidoscope, or BBEdit, then reopen Settings.
            """)
        }
        let names = installedDiffTools.map(\.displayName).joined(separator: ", ")
        return String(localized: """
        The tool Compare By Contents (⌥F3) opens the two files in. Installed: \(names). \
        Automatic picks the first of those still installed.
        """)
    }
}
