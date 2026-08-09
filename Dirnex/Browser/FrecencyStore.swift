import DirnexCore
import Foundation

/// App-wide persistence for the frecency index (PLAN.md §M3 "Frecency jump: … visit
/// tracking … zoxide-style scoring"). One shared index across every window and pane, so a
/// directory visited on the left learns the same as one visited on the right. Stored as
/// boring JSON in `UserDefaults` like `TabPersistence`/`FavoritesStore`/the command recents
/// (PLAN.md §2 "JSON/plist for config"); the plan pencils in SQLite for when the undo
/// journal shares this DB, deferred for the same reason it was for undo.
///
/// Held in memory and mutated in place (unlike `FavoritesStore`, which reads fresh per menu
/// open) because visits stream in continuously from every navigation — reloading the whole
/// index on each one, and racing separate copies between windows, would both be wrong. The
/// single shared instance is the one writer.
@MainActor
final class FrecencyStore {
    static let shared = FrecencyStore()

    private let defaults: UserDefaults
    private let key = "Dirnex.frecency"
    private var frecency: Frecency

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(Frecency.self, from: data) {
            frecency = decoded
        } else {
            frecency = Frecency()
        }
    }

    /// Record a successful navigation to `path`, bumping its frecency and persisting the
    /// index. Called from every pane's `navigate`, so it learns from crumb clicks, the
    /// sidebar, favorites jumps, and back/forward alike.
    func recordVisit(_ path: VFSPath) {
        // Only local directories belong in the fuzzy-jump index: it navigates by typing a path
        // fragment and picks the first candidate that still exists on disk, which a remote SFTP
        // location or a virtual archive/search path can't satisfy.
        guard path.backend == .local else { return }
        // And nothing from inside an unlocked vault, ever (PLAN.md §M19 / `VaultPrivacy`). This
        // index is written to `UserDefaults` in the clear and outlives the vault being locked, so
        // without this line browsing a vault leaves a list of its folder names sitting outside the
        // encrypted image — which is the one thing a vault exists to prevent.
        guard !VaultMounts.shared.contains(path) else { return }
        frecency.visit(path)
        persist()
    }

    /// Drop every remembered directory under `mountPoint` — called when a vault locks, so that
    /// anything recorded before Dirnex knew it was a vault (an image unlocked in Disk Utility, in
    /// the moment before the mount notification landed) goes with it.
    func forget(pathsUnder mountPoint: String) {
        let removed = frecency.forget { VaultPrivacy.isInside($0, mountPoints: [mountPoint]) }
        guard removed else { return }
        persist()
    }

    /// Directories whose folder name fuzzily matches `fragment`, best-scored first — the
    /// path bar's "dl → ~/Downloads" candidates. The pane picks the first that still exists.
    func rankedMatches(for fragment: String) -> [VFSPath] {
        frecency.matches(for: fragment).map(\.path)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(frecency) else { return }
        defaults.set(data, forKey: key)
    }
}
