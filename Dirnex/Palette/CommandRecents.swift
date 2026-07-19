import DirnexCore
import Foundation

/// Remembers the command ids the user has run from the palette, most-recent first, so the
/// palette can float them to the top (PLAN.md §M3 "recents on top"). Boring `UserDefaults`
/// persistence, matching `TabPersistence` and the undo journal; the SQLite frecency store
/// the plan mentions arrives with the M3 frecency-jump item.
struct CommandRecents {
    private let defaults: UserDefaults
    private let key = "Dirnex.commandRecents"
    /// Enough to keep the palette's resting list useful without unbounded growth.
    private let capacity = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored ids, newest first, filtered to commands that still exist in the registry
    /// (so a renamed/removed command id doesn't linger).
    var ids: [String] {
        let stored = defaults.stringArray(forKey: key) ?? []
        let known = Set(CommandCatalog.all.map(\.id))
        return stored.filter(known.contains)
    }

    /// Record `id` as the most recently run command, de-duplicating and capping the list.
    func record(_ id: String) {
        var updated = ids.filter { $0 != id }
        updated.insert(id, at: 0)
        if updated.count > capacity {
            updated.removeLast(updated.count - capacity)
        }
        defaults.set(updated, forKey: key)
    }
}
