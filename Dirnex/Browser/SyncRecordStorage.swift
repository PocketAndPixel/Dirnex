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
    /// with no box to tick (``SyncRecordPair``). One side may be on a server since PLAN.md §M38
    /// Slice 9: such a record keeps what each sync copied, and reads the server's side by its stamp.
    init?(left: VFSPath, right: VFSPath, store: SyncRecordStore?, vaultMountPoints: [String]) {
        guard let store, let pair = SyncRecordPair(
            left: left,
            right: right,
            vaultMountPoints: vaultMountPoints,
            allowingServerSide: true
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

    /// The side on a server, or `nil` when both are on this disk (PLAN.md §M38 Slice 9).
    var server: FileEntry? {
        records.pair.serverFolder == nil ? nil : [left, right].first { $0.path.backend != .local }
    }

    /// The file on this disk that Save writes first: the left one of a local pair, else the side that
    /// is not on the server.
    var local: FileEntry {
        server.map { $0.path == left.path ? right : left } ?? left
    }
}
