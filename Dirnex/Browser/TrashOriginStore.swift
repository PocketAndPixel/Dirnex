import DirnexCore
import Foundation

/// App-wide persistence for the put-back records Dirnex writes for its own deletes
/// (PLAN.md §M26 Slice 4), and the live half of the two rules ``TrashOriginRecords`` states.
///
/// Boring JSON in `UserDefaults`, like `TabPersistence`/`FavoritesStore`/`FrecencyStore` (PLAN.md §2
/// "JSON/plist for config"). Held in memory and mutated in place for the same reason the frecency
/// index is: writes stream in from every delete in every window, and reloading the whole store per
/// delete would race separate copies between them.
///
/// The two rules it owns are the ones only the app can answer:
///
/// - **The vault guard.** ``VaultMounts`` holds the live mount points, so the predicate
///   ``TrashOriginRecords/record(_:unless:)`` takes comes from here — a record pairs a file's name
///   with the folder it came from and outlives both, which is exactly the implicit memory PLAN.md
///   §M19 keeps a vault's contents out of.
/// - **When to prune.** The store is trimmed on the pass that is *already* enumerating the trashes
///   (``PanelViewController/gatherTrash(then:)``), scoped to the directories that pass actually
///   managed to read.
@MainActor
final class TrashOriginStore {
    /// A `var` rather than a `let`, and for exactly one reason: the **write** side is otherwise
    /// unreachable from a test. A delete that quietly stopped filing its origin would leave every
    /// other test here green while Put Back had nothing to answer from — the "opt-in seam whose
    /// default is do-nothing" failure docs/NOTES.md records, and the one this store exists to
    /// prevent. Nothing in the app reassigns it.
    static var shared = TrashOriginStore()

    private let defaults: UserDefaults
    private let key = "Dirnex.putBackOrigins"
    private var records: TrashOriginRecords
    /// Whether a path is inside an unlocked vault. Injected rather than read from
    /// ``VaultMounts/shared`` at the call site so the rule is *reachable*: on a Mac with no vault
    /// attached the singleton answers `false` to everything, so a store that had quietly stopped
    /// asking would pass every test there is (docs/NOTES.md ▸ Testing, a rule whose input is read by
    /// the rule is a rule with one test case).
    private let isInVault: @MainActor (VFSPath) -> Bool

    init(
        defaults: UserDefaults = .standard,
        isInVault: @escaping @MainActor (VFSPath) -> Bool = { VaultMounts.shared.contains($0) }
    ) {
        self.defaults = defaults
        self.isInVault = isInVault
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(TrashOriginRecords.self, from: data) {
            records = decoded
        } else {
            records = TrashOriginRecords()
        }
    }

    /// The value a restore pass reads, taken on the main actor and carried into the blocking work
    /// that does the matching — the store is a `@MainActor` object and the records are a `Sendable`
    /// value, which is the whole reason the two are separate types.
    var snapshot: TrashOriginRecords { records }

    /// File what a Trash pass moved. Called from every flow that trashes, beside the undo record
    /// that has always been written from the same data.
    func record(_ restorations: [DeletePass.Restoration]) {
        guard !restorations.isEmpty else { return }
        let changed = records.record(restorations, unless: isInVault)
        guard changed else { return }
        persist()
    }

    /// Where the item now at `trashed` came from, for a caller that has only one to ask about.
    /// `finderRecord` wins wherever there is one — the merge rule lives in the core value.
    func origin(of trashed: VFSPath, finderRecord: TrashOrigin?) -> TrashOrigin? {
        records.origin(of: trashed, finderRecord: finderRecord)
    }

    /// Drop records for items that have left the Trash, from the gather that just listed it.
    ///
    /// Scoped to `trashesRead` rather than to every trash there is: a volume that unmounted between
    /// the enumeration and the listing contributes no entries at all, and pruning against the merged
    /// set would throw away every record it owns.
    func prune(stillTrashed entries: [FileEntry], inTrashesRead trashesRead: [VFSPath]) {
        let changed = records.prune(
            stillTrashed: Set(entries.map(\.path)),
            inTrashesRead: Set(trashesRead)
        )
        guard changed else { return }
        persist()
    }

    /// Drop every record naming something under `mountPoint` — called when a vault locks, exactly as
    /// `FrecencyStore.forget(pathsUnder:)` is, and for the same case the guard above cannot cover:
    /// an image unlocked outside Dirnex and browsed in the window before the mount notification
    /// landed.
    func forget(pathsUnder mountPoint: String) {
        let changed = records.forget { VaultPrivacy.isInside($0, mountPoints: [mountPoint]) }
        guard changed else { return }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}
