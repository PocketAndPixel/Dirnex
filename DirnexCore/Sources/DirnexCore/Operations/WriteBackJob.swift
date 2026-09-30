import Foundation

/// One edited copy on its way back to where it came from (PLAN.md §4 ▸ *Still open*, taken
/// 2026-09-01).
///
/// A **pair** rather than a `FileEntry`, because neither end of it is a row anybody listed: the
/// source is a temp copy an editor has open, and the destination is a remote path whose current
/// contents are precisely what this write replaces. Carrying the local path as a `String` matches
/// ``MaterializedFile`` — the mirror value on the download side — for the same reason it does
/// there: the copy is a real file on this disk and nothing about it needs a backend.
public struct RemoteWriteBackItem: Sendable, Equatable {
    /// The edited copy, an absolute path on this disk.
    public let localPath: String
    /// Where it goes back to. Carries its own backend, so a batch spanning two accounts is one job.
    public let destination: VFSPath
    /// The precondition this item's write carries, decided by the check that preceded the job.
    ///
    /// **Per item, never per job**, and that is the load-bearing part: a batch is a set of
    /// independent files, each with its own entity tag, and one condition shared across them could
    /// only ever be `.unconditional`. It also has to have been read off the **check's** revision
    /// rather than the download's, which is the rule `BrowserWindowController.writeCondition` owns
    /// and this type only carries.
    public let condition: S3WriteCondition
    /// What the copy weighs, for the bar. Read once when the batch is assembled rather than
    /// `stat`ed again in the runner: the file is on this disk, so it is free either way, and
    /// taking it here keeps the runner's denominator known before the first byte moves.
    public let byteSize: Int64
    /// The name to put in a sentence about this item. The destination's last component would
    /// usually do, and *usually* is the problem — a save-back is the one flow where the user is
    /// thinking of the file they have open in an editor.
    public let name: String

    public init(
        localPath: String,
        destination: VFSPath,
        condition: S3WriteCondition = .unconditional,
        byteSize: Int64,
        name: String
    ) {
        self.localPath = localPath
        self.destination = destination
        self.condition = condition
        self.byteSize = byteSize
        self.name = name
    }
}

/// A batch of edited copies to put back, as one queued job (PLAN.md §4 ▸ *Still open*).
///
/// The mirror of `.materialize`, and it exists for the reason that one does: a marked set is the
/// shape these gestures have, and an N-file transfer needs a determinate bar, a Stop, per-item
/// failures and the queue's ordering — all of which exist already and none of which is worth a
/// second implementation. Before this, a user script that rewrote forty files on a server produced
/// forty independent uploads, each `stat`ing and uploading on its own with no bar, no Stop and no
/// ordering between them.
///
/// **Every save-back comes here, including a single ⌘S.** Two spellings of "upload an edited file"
/// is the one-rule-several-spellings shape this project keeps paying for, and the download side
/// already settled the same question the same way — a one-row Open With fetch goes through
/// `.materialize` with no single-file branch.
///
/// The items ride in the job rather than in ``FileOperation/sources`` because they are pairs, and
/// because `sources` is `[FileEntry]` — rows from a listing, which neither end of a write-back is.
/// The same reason ``ChecksumJob``, ``AttributeApplyJob`` and ``PackJob`` carry their own payloads.
public struct WriteBackJob: Sendable, Equatable {
    public let items: [RemoteWriteBackItem]

    public init(items: [RemoteWriteBackItem]) {
        self.items = items
    }

    /// What the whole batch weighs — the bar's denominator, known before the first byte moves.
    public var totalBytes: Int64 {
        items.reduce(into: Int64(0)) { $0 += max(0, $1.byteSize) }
    }
}
