import DirnexCore
import Foundation

/// Where this app keeps the copies that make an archive rewrite undoable (HISTORY.md ▸ After M19,
/// 2026-09-01) — the one `ArchiveUndoStore` every rewrite captures into and every launch prunes.
///
/// `Application Support`, not `Caches`, and the difference is the journal: the undo stack survives
/// relaunch, so a snapshot the OS may evict under space pressure would leave a record pointing at
/// bytes that are gone — reported to the user, but for no reason they could have foreseen. The
/// store excludes itself from Time Machine instead (``ArchiveUndoStore``), which is the part of
/// "cache" that genuinely applies: the user still has every archive these describe.
enum ArchiveUndoStorage {
    /// The store, or `nil` on the Mac where Application Support cannot be created — in which case
    /// archive rewrites go on being what they have always been, non-undoable, and the confirmation
    /// sheets say so.
    static let shared: ArchiveUndoStore? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return ArchiveUndoStore(
            root: support
                .appendingPathComponent("Dirnex", isDirectory: true)
                .appendingPathComponent("ArchiveUndo", isDirectory: true)
        )
    }()

    /// Whether a rewrite of the archive at `path` will be undoable — the question the confirmation
    /// sheets ask *before* they run, so none of them promises a reversal it will not deliver.
    ///
    /// Asked of the archive's size alone (``ArchiveUndoBudget/admits(archiveOfSize:)``); see that
    /// method for why the store's current contents are deliberately not consulted.
    static func willBeUndoable(archiveAt path: String) -> Bool {
        guard let store = shared,
              let witness = ArchiveUndoWitness.current(ofFileAt: path)
        else { return false }
        return store.budget.admits(archiveOfSize: witness.byteSize)
    }

    /// The store and the order it may evict in, taken together.
    ///
    /// One value rather than two parameters, and `ArchiveWriter` takes it with **no default**, for
    /// a reason this project has paid for elsewhere: the app test target runs *inside the app*, so
    /// any app-wide store a test can reach is the developer's own. A defaulted `undo:` meant every
    /// existing rewrite test quietly filed a snapshot of its fixture into
    /// `~/Library/Application Support/Dirnex` — well-formed, so nothing downstream complained.
    /// Making it a required argument is the compiler enforcing the isolation instead of a habit
    /// each new test has to remember.
    struct Request: Sendable {
        let store: ArchiveUndoStore?
        let live: [String]

        /// For a caller that does not want a rewrite journalled at all — a test, or a Mac where
        /// Application Support could not be created.
        static let none = Request(store: nil, live: [])
    }

    /// What the app's own rewrites capture into.
    nonisolated static func request() -> Request {
        Request(store: shared, live: liveSnapshots())
    }

    /// Every snapshot the journal still names, in the order they may be given up.
    ///
    /// Read from the *persisted* stacks rather than from a live `UndoController`, which is exact
    /// because the controller writes them on every change — and is what lets a capture run off the
    /// main actor, where a rewrite already is.
    nonisolated static func liveSnapshots() -> [String] {
        UndoController.persistedArchiveSnapshots()
    }

    /// Drop every snapshot the persisted journal no longer names. Called once at launch, beside the
    /// other purges, where nothing is rewriting yet and the journal on disk *is* the live set.
    ///
    /// It has to read the persisted stacks rather than a live `UndoController`, because the windows
    /// that own those have not been built yet — and that is the right source anyway: a snapshot
    /// outlives its record exactly when the record fell off the bottom of the stack between
    /// launches, which is what the file records.
    static func purgeUnreferenced() {
        shared?.prune(live: Set(UndoController.persistedArchiveSnapshots()))
    }
}
