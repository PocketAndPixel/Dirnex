import AppKit
import DirnexCore

/// Workspaces (PLAN.md §M3 "Workspaces: save/restore both panels with all tabs, named,
/// switchable from palette"). A workspace is a whole-window concept — both panes and their
/// tabs — so the capture/restore that spans the two panes lives on the window controller
/// (`BrowserWindowController+Workspaces`); the pane owns the per-pane snapshot/restore and the
/// menu/palette actions, dispatched to the focused pane via the responder chain like the
/// favorites. The shared list lives in `WorkspaceStore`; reorder/rename/delete happen in the
/// organizer sheet (`WorkspaceOrganizerController`).
extension PanelViewController {
    // MARK: - Snapshot / restore (one pane)

    /// This pane's tabs frozen into a `WorkspacePane` — the directory and sort of each tab plus
    /// which one is active. Column geometry is intentionally left out (see `WorkspaceTab`).
    func workspaceSnapshot() -> WorkspacePane {
        let snapshotTabs = tabs.map { WorkspaceTab(path: $0.panel.path, sort: $0.panel.model.sort) }
        return WorkspacePane(tabs: snapshotTabs, activeTabIndex: activeTabIndex)
    }

    /// Replace this pane's tabs with a saved workspace pane and show its active tab. Directories
    /// that have since vanished are dropped (matching relaunch restoration); if every one is
    /// gone, the pane keeps its current directory rather than ending up tab-less.
    func restore(workspacePane pane: WorkspacePane) {
        let restored: [PanelTab] = pane.tabs.compactMap { tab in
            let path = tab.path
            var isDirectory: ObjCBool = false
            guard path.backend == .local,
                  FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return PanelTab(path: path, sort: tab.sort)
        }
        tabs = restored.isEmpty
            ? [PanelTab(path: panel.path, sort: panel.model.sort)]
            : restored
        activeTabIndex = min(max(pane.activeTabIndex, 0), tabs.count - 1)
        activateTab()
        persistState()
    }

    // MARK: - Commands (dispatched to the focused pane via the responder chain)

    /// "Workspaces…" — drop the switch list just under the path bar: one item per saved
    /// workspace (restore on pick), then Save and Manage.
    @objc func showWorkspaces(_ sender: Any?) {
        let menu = buildWorkspacesMenu()
        let origin = NSPoint(x: 8, y: pathBar.isFlipped ? pathBar.bounds.maxY : 0)
        menu.popUp(positioning: nil, at: origin, in: pathBar)
    }

    /// "Save Workspace…" — prompt for a name, then snapshot both panes under it. Re-using an
    /// existing name updates that workspace in place after a replace confirmation.
    @objc func saveWorkspace(_ sender: Any?) {
        guard let name = promptForWorkspaceName() else { return }
        var store = WorkspaceStore.load()
        if store.contains(name: name), !confirmReplaceWorkspace(named: name) { return }
        guard let host else { return }
        store.save(host.captureWorkspace(named: name))
        WorkspaceStore.save(store)
    }

    // MARK: - Popup menu

    private func buildWorkspacesMenu() -> NSMenu {
        let menu = NSMenu()
        let workspaces = WorkspaceStore.load()

        if workspaces.workspaces.isEmpty {
            let empty = NSMenuItem(title: "No Saved Workspaces", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (index, workspace) in workspaces.workspaces.enumerated() {
                menu.addItem(workspaceItem(for: workspace, index: index))
            }
        }

        menu.addItem(.separator())

        let save = NSMenuItem(
            title: "Save Workspace…",
            action: #selector(saveWorkspace(_:)),
            keyEquivalent: ""
        )
        save.target = self
        menu.addItem(save)

        let manage = NSMenuItem(
            title: "Manage Workspaces…",
            action: #selector(manageWorkspaces(_:)),
            keyEquivalent: ""
        )
        manage.target = self
        manage.isEnabled = !workspaces.workspaces.isEmpty
        menu.addItem(manage)

        return menu
    }

    /// One switch item, carrying its workspace *name* so a mid-open store change can't restore
    /// the wrong (index-shifted) workspace. The first nine get a bare 1–9 accelerator, usable
    /// while the menu is open (matching the favorites popup).
    private func workspaceItem(for workspace: Workspace, index: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: workspace.name,
            action: #selector(switchToWorkspace(_:)),
            keyEquivalent: index < 9 ? String(index + 1) : ""
        )
        item.keyEquivalentModifierMask = []
        item.target = self
        item.representedObject = workspace.name
        item.image = Self.workspaceIcon
        return item
    }

    /// A two-pane glyph for the switch items, so a workspace reads as a whole-window layout
    /// rather than a folder.
    private static let workspaceIcon: NSImage? = {
        let image = NSImage(
            systemSymbolName: "square.split.2x1",
            accessibilityDescription: "Workspace"
        )
        image?.size = NSSize(width: 16, height: 16)
        image?.isTemplate = true
        return image
    }()

    // MARK: - Actions

    @objc private func switchToWorkspace(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let workspace = WorkspaceStore.load().workspace(named: name) else { return }
        host?.applyWorkspace(workspace)
    }

    @objc private func manageWorkspaces(_ sender: Any?) {
        // `presentAsSheet` retains the organizer for its on-screen lifetime, so the pane
        // doesn't need to hold it.
        presentAsSheet(WorkspaceOrganizerController())
    }

    // MARK: - Prompts

    /// Ask for a workspace name, returning the trimmed non-empty result, or `nil` on cancel /
    /// an empty name.
    private func promptForWorkspaceName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Save both panels and all their tabs so you can switch back to this layout."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Confirm overwriting a workspace that already uses this name, so a Save never silently
    /// clobbers a saved layout.
    private func confirmReplaceWorkspace(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace “\(name)”?"
        alert.informativeText = "A workspace named “\(name)” already exists. Replace it with the current layout?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
