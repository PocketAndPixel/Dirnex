import DirnexCore
import SwiftUI

/// The Settings ▸ Shortcuts tab (PLAN.md §M3 "rebindable shortcuts with conflict detection").
/// Lists every registry command grouped by category with an inline recorder, flags collisions,
/// and restores the defaults — all editing the shared `KeyBindingStore`, which the menu bar and
/// palette read live. There is one scheme; the Total Commander preset beside it was removed on
/// 2026-10-21 (`KeyBindings`).
struct ShortcutsSettingsView: View {
    @ObservedObject var store: KeyBindingStore
    @State private var query = ""

    /// Whether the "restore defaults" confirmation is showing.
    @State private var confirmingRestore = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            Form {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = filteredCommands(in: category)
                    if !commands.isEmpty {
                        Section(category.localizedTitle) {
                            ForEach(commands, id: \.id) { command in
                                row(for: command)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .alert("Restore default shortcuts?", isPresented: $confirmingRestore) {
            Button("Restore Defaults", role: .destructive) { store.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                """
                All your shortcut customizations will be removed and the default shortcuts restored. All \
                your changes will be lost.
                """
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            // A fixed width rather than a cap: beside a `Spacer`, a capped field is offered only an
            // even share of the free space and comes out narrower. 208 leaves room for the longest
            // Restore Defaults label, Italian's, measured at 244 pt.
            TextField("Filter", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 208)

            if store.bindings.hasConflicts {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Some shortcuts are assigned to more than one command.")
            }

            Spacer()

            SettingsButton("Restore Defaults") { confirmingRestore = true }
                .disabled(store.bindings.overrides.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for command: Command) -> some View {
        let conflicts = store.bindings.conflicts(for: command.id)
        HStack(spacing: 8) {
            Text(command.title)
            Spacer(minLength: 8)

            if !conflicts.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Also assigned to \(conflictNames(conflicts))")
            }

            if store.bindings.isCustomized(command.id) {
                Button {
                    store.reset(command.id)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            }

            ShortcutRecorder(
                shortcut: store.bindings.shortcut(for: command.id),
                isConflicting: !conflicts.isEmpty,
                onRecord: { store.setShortcut($0, for: command.id) }
            )
            .frame(width: 148, height: 24)
        }
    }

    // MARK: - Helpers

    private func filteredCommands(in category: CommandCategory) -> [Command] {
        LocalizedCatalog.all.filter { command in
            guard command.category == category else { return false }
            guard !query.isEmpty else { return true }
            return command.title.localizedCaseInsensitiveContains(query)
                || command.keywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func conflictNames(_ ids: [String]) -> String {
        ids.compactMap { LocalizedCatalog.command(for: $0)?.title }
            .joined(separator: ", ")
    }
}
