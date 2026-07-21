import Foundation

/// One tab saved inside a workspace pane: the directory it shows and how it's sorted
/// (PLAN.md §M3 "Workspaces: save/restore both panels with all tabs"). Deliberately lighter
/// than the app's `PersistedTab` — column geometry is a per-tab view nicety the app restores
/// to its default rather than a part of a named workspace's identity.
public struct WorkspaceTab: Sendable, Equatable, Codable {
    public let path: VFSPath
    public let sort: FileSort

    public init(path: VFSPath, sort: FileSort = .default) {
        self.path = path
        self.sort = sort
    }
}

/// One pane's saved state within a workspace: its ordered tabs and which one was active.
/// The active index is kept valid against the tab count so a hand-edited or truncated store
/// can never point past the end.
public struct WorkspacePane: Sendable, Equatable, Codable {
    public private(set) var tabs: [WorkspaceTab]
    public private(set) var activeTabIndex: Int

    public init(tabs: [WorkspaceTab], activeTabIndex: Int) {
        self.tabs = tabs
        self.activeTabIndex = Self.clamp(activeTabIndex, tabCount: tabs.count)
    }

    /// Keep `activeTabIndex` in `0..<tabs.count` (or 0 when empty) so the app can index into
    /// `tabs` with it directly.
    private static func clamp(_ index: Int, tabCount: Int) -> Int {
        guard tabCount > 0 else { return 0 }
        return min(max(index, 0), tabCount - 1)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case tabs
        case activeTabIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the memberwise init so a stored index is re-clamped against
        // however many tabs actually survived.
        self.init(
            tabs: try container.decode([WorkspaceTab].self, forKey: .tabs),
            activeTabIndex: try container.decodeIfPresent(Int.self, forKey: .activeTabIndex) ?? 0
        )
    }
}

/// A named snapshot of the whole browser window — both panes and all their tabs — that the
/// user can save and switch back to (PLAN.md §M3 "Workspaces: … named, switchable from
/// palette"). Identity is the name, so a workspace is saved once per name (re-saving under an
/// existing name updates it in place).
public struct Workspace: Sendable, Equatable, Identifiable, Codable {
    /// The user-facing label shown in the switch menu, the palette, and the organizer — and
    /// the workspace's identity: at most one workspace per name.
    public var name: String
    public var left: WorkspacePane
    public var right: WorkspacePane

    public init(name: String, left: WorkspacePane, right: WorkspacePane) {
        self.name = name
        self.left = left
        self.right = right
    }

    public var id: String { name }
}

/// An ordered, name-de-duplicated collection of saved workspaces — the model behind the
/// Workspace menu's switch list and the organizer. A pure value type with no persistence or
/// AppKit: the app owns the `UserDefaults` store and the menu/organizer UI, this owns the
/// ordering and naming rules so they stay unit-testable headless (matching `Favorites`,
/// `NavigationHistory`, and the command registry).
public struct Workspaces: Sendable, Equatable, Codable {
    /// The saved workspaces in user order — the order the switch menu and organizer present,
    /// and the order the organizer's drag-reorder rewrites.
    public private(set) var workspaces: [Workspace]

    public init(workspaces: [Workspace] = []) {
        // Collapse duplicate names on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a name maps to a single workspace.
        var seen = Set<String>()
        self.workspaces = workspaces.filter { seen.insert($0.name).inserted }
    }

    /// Whether a workspace named `name` exists — drives the Save prompt's replace confirmation.
    public func contains(name: String) -> Bool {
        workspaces.contains { $0.name == name }
    }

    /// The workspace named `name`, or `nil` — the switch menu looks one up by name so a
    /// mid-open store change can't restore the wrong (index-shifted) workspace.
    public func workspace(named name: String) -> Workspace? {
        workspaces.first { $0.name == name }
    }

    /// Save `workspace`: overwrite an existing one with the same name *in place* (keeping its
    /// position), else append. Returns whether it replaced an existing workspace — the app
    /// only asks the user to confirm a replacement.
    @discardableResult
    public mutating func save(_ workspace: Workspace) -> Bool {
        if let index = workspaces.firstIndex(where: { $0.name == workspace.name }) {
            workspaces[index] = workspace
            return true
        }
        workspaces.append(workspace)
        return false
    }

    /// Delete the workspace named `name`, if present. Returns whether one was removed.
    @discardableResult
    public mutating func remove(name: String) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.name == name }) else { return false }
        workspaces.remove(at: index)
        return true
    }

    /// Delete the workspace at `index` (the organizer's − button); out-of-range is ignored.
    public mutating func remove(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        workspaces.remove(at: index)
    }

    /// Rename the workspace at `name` to `newName` — the organizer's inline edit. Rejected
    /// (returns `false`, leaving the list unchanged) when `newName` is empty or already names a
    /// *different* workspace, so a rename can never collapse two entries into one. Renaming to
    /// the same name is a no-op success.
    @discardableResult
    public mutating func rename(name: String, to newName: String) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.name == name }) else { return false }
        guard !newName.isEmpty else { return false }
        guard !workspaces.contains(where: { $0.name == newName }) || newName == name else {
            return false
        }
        workspaces[index].name = newName
        return true
    }

    /// Reorder: pull the workspace out of `source` and reinsert it so it lands at `destination`
    /// in the *resulting* list (Array semantics, matching the favorites reorder). The UI adjusts a
    /// raw `NSTableView` drop row into this convention before calling.
    public mutating func move(from source: Int, to destination: Int) {
        guard workspaces.indices.contains(source) else { return }
        let workspace = workspaces.remove(at: source)
        workspaces.insert(workspace, at: min(max(destination, 0), workspaces.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case workspaces
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in.
        self.init(workspaces: try container.decode([Workspace].self, forKey: .workspaces))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaces, forKey: .workspaces)
    }
}
