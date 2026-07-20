import Foundation

/// One pinned directory in the hotlist (PLAN.md §M3 "Directory hotlist (Ctrl+D): pin,
/// reorder, jump").
public struct HotlistEntry: Sendable, Hashable, Identifiable, Codable {
    /// The label shown in the hotlist menu and organizer. Defaults to the folder's own
    /// name but is user-editable, so a short "Projects" can stand in for a deep path.
    public var name: String
    /// Where the entry jumps to — and the entry's identity: a path is pinned at most once.
    public let path: VFSPath

    public init(name: String, path: VFSPath) {
        self.name = name
        self.path = path
    }

    /// Pin `path` under its own folder name (the backend root shows as "/").
    public init(path: VFSPath) {
        self.init(name: path.lastComponent, path: path)
    }

    public var id: VFSPath { path }
}

/// An ordered, de-duplicated list of pinned directories — the model behind the Ctrl+D
/// hotlist (PLAN.md §M3). A pure value type with no persistence or AppKit: the app owns the
/// `UserDefaults` store and the menu/organizer UI, this owns the ordering rules so they stay
/// unit-testable headless (matching `Panel`, `SidebarLocations`, and the command registry).
public struct Hotlist: Sendable, Equatable, Codable {
    /// The pinned entries in user order — the order the menu and organizer present, and the
    /// order the organizer's drag-reorder rewrites.
    public private(set) var entries: [HotlistEntry]

    public init(entries: [HotlistEntry] = []) {
        // Collapse duplicate paths on the way in (a hand-edited or legacy store), keeping the
        // first occurrence so a path maps to a single position.
        var seen = Set<VFSPath>()
        self.entries = entries.filter { seen.insert($0.path).inserted }
    }

    /// Whether `path` is already pinned — drives the menu's Add/Remove toggle.
    public func contains(_ path: VFSPath) -> Bool {
        entries.contains { $0.path == path }
    }

    /// Pin `entry` at the end, unless its path is already pinned — in which case it's a no-op
    /// (re-pinning never duplicates an entry or disturbs its position). Returns whether it was
    /// actually added.
    @discardableResult
    public mutating func add(_ entry: HotlistEntry) -> Bool {
        guard !contains(entry.path) else { return false }
        entries.append(entry)
        return true
    }

    /// Unpin the entry at `path`, if present. Returns whether one was removed.
    @discardableResult
    public mutating func remove(path: VFSPath) -> Bool {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return false }
        entries.remove(at: index)
        return true
    }

    /// Remove the entry at `index` (the organizer's − button); out-of-range is ignored.
    public mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
    }

    /// Rename the entry at `path`, if present — the organizer's inline edit.
    public mutating func rename(path: VFSPath, to name: String) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        entries[index].name = name
    }

    /// Insert `entry` so it lands at `index` in the resulting list — the drop half of the sidebar's
    /// drag-and-drop (PLAN.md §M8), where `move` is the reorder half.
    ///
    /// A path that is **already pinned moves rather than duplicating**, and keeps its existing
    /// entry: dragging in a folder that is already in the sidebar is a reposition, and a user-given
    /// name on it ("Work" for `~/Dev/Projects`) has to survive being dragged. That mirrors `add`'s
    /// refusal to rename on a duplicate. Out-of-range indices clamp to the ends.
    ///
    /// Returns whether the list actually changed, so a caller can skip a needless write.
    @discardableResult
    public mutating func insert(_ entry: HotlistEntry, at index: Int) -> Bool {
        let before = entries
        var working = entries
        var repositioned: HotlistEntry?
        if let existing = working.firstIndex(where: { $0.path == entry.path }) {
            repositioned = working.remove(at: existing)
        }
        working.insert(repositioned ?? entry, at: min(max(index, 0), working.count))
        entries = working
        return entries != before
    }

    /// Reorder: pull the entry out of `source` and reinsert it so it lands at `destination`
    /// in the *resulting* list (Array semantics, matching the tab reorder). The UI adjusts a
    /// raw `NSTableView` drop row into this convention before calling.
    public mutating func move(from source: Int, to destination: Int) {
        guard entries.indices.contains(source) else { return }
        let entry = entries.remove(at: source)
        entries.insert(entry, at: min(max(destination, 0), entries.count))
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Route decoding through the de-duplicating initializer so a legacy/corrupt store is
        // sanitized on the way back in.
        self.init(entries: try container.decode([HotlistEntry].self, forKey: .entries))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }
}
