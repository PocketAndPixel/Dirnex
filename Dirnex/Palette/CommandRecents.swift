import DirnexCore
import Foundation

/// Remembers the command ids the user has run from the palette, most-recent first, so the
/// palette can float them to the top (PLAN.md §M3 "recents on top"). Boring `UserDefaults`
/// persistence, matching `TabPersistence` and the undo journal; the SQLite frecency store
/// the plan mentions arrives with the M3 frecency-jump item.
///
/// **Kept to the ids the palette offers now**, which the palette hands in. That was the registry
/// alone until M40, so a user script never showed as recent, and a place or a workspace (PLAN.md
/// §M40 Slice 1) would not have either. The palette's own list is the right measure for all three: a
/// renamed command, a deleted script and an unpinned folder each drop out at the next pick rather
/// than holding one of the twelve places.
struct CommandRecents {
    private let defaults: UserDefaults
    private let key = "Dirnex.commandRecents"
    /// Enough to keep the palette's resting list useful without unbounded growth.
    private let capacity = 12

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored ids, newest first, that `offered` still holds.
    func ids(among offered: Set<String>) -> [String] {
        let stored = defaults.stringArray(forKey: key) ?? []
        return stored.filter(offered.contains)
    }

    /// Record `id` as the most recently run, de-duplicating, dropping what `offered` no longer holds,
    /// and capping the list.
    func record(_ id: String, among offered: Set<String>) {
        var updated = ids(among: offered).filter { $0 != id }
        updated.insert(id, at: 0)
        if updated.count > capacity {
            updated.removeLast(updated.count - capacity)
        }
        defaults.set(updated, forKey: key)
    }
}
