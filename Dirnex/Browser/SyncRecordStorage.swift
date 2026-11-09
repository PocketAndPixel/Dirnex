import DirnexCore
import Foundation

/// Where this app keeps what its syncs left equal (PLAN.md §M37 Slice 8).
///
/// `Application Support`, as the undo store is: a record outlives the session that made it, since
/// the next sync of that pair may be months away.
enum SyncRecordStorage {
    /// The store, or `nil` on the Mac where Application Support cannot be created, where Synchronize
    /// simply has no box to tick.
    ///
    /// Not a default anywhere: the app test target runs inside the app, so a default would be how a
    /// test files its fixtures into the developer's own store (`ArchiveUndoStorage.Request`).
    static let shared: SyncRecordStore? = {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return SyncRecordStore(parent: support.appendingPathComponent("Dirnex", isDirectory: true))
    }()

    /// Clear what no record names. Called once at launch, beside the other purges, where no sync
    /// can have files its record does not name yet.
    static func purgeUnreferenced() {
        shared?.purge()
    }
}

/// The record a Synchronize window can reach: its store and its pair of folders.
struct SyncRecordAccess: Sendable {
    let store: SyncRecordStore
    let pair: SyncRecordPair

    /// The record of these two folders, or `nil` when they cannot have one, which leaves the window
    /// with no box to tick (``SyncRecordPair``).
    init?(left: VFSPath, right: VFSPath, store: SyncRecordStore?, vaultMountPoints: [String]) {
        guard let store, let pair = SyncRecordPair(
            left: left,
            right: right,
            vaultMountPoints: vaultMountPoints
        ) else { return nil }
        self.store = store
        self.pair = pair
    }
}

/// What a sync does with the pair's record once it has run.
enum SyncRecordChoice: Sendable {
    /// Keep what the sync left equal, remembering the pair if it was not already.
    case keep(SyncRecordAccess)
    /// Stop remembering the pair, and remove what was kept.
    case forget(SyncRecordAccess)
}

/// One row's merge, as the Synchronize window hands it to the pane.
struct SyncMergeRequest: Sendable {
    let relativePath: String
    let left: FileEntry
    let right: FileEntry
    /// The version both sides last held.
    let base: URL
    let records: SyncRecordAccess
}
