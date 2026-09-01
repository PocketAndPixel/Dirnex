import DirnexCore
import Foundation

/// One archive's worth of edited members, on their way back in (PLAN.md §4 ▸ *Still open*, taken
/// 2026-09-01).
///
/// The unit of an archive write-back, because it is the unit of the thing itself: a rewrite is
/// extract → mutate → repack → swap over the **container**, so what it costs is the archive's size
/// and not how many members changed. Grouping is therefore not a tidying of the flow, it is the
/// difference between one pass and N.
struct ArchiveWriteBackGroup: Equatable {
    let archivePath: String
    /// The saves going into it, in the order the batch gathered them.
    let items: [PendingArchiveWriteBack]

    /// What the rewrite copies in, each with the folder it belongs to.
    ///
    /// Pairs rather than one directory and a list, because members saved together can have come
    /// from **different folders inside the archive** and still belong in one pass — which is
    /// exactly what the single-directory spelling of `ArchiveWriter.add` could not express.
    var additions: [ArchiveMutation.Addition] {
        items.map {
            ArchiveMutation.Addition(
                localPath: $0.edit.temporaryURL.path,
                innerDirectory: $0.innerDirectory
            )
        }
    }
}

/// Turning a gathered batch into one group per archive, with no window and no `bsdtar`.
///
/// Split out for the reason every rule in this area is: the grouping is what the whole change is,
/// and presenting a real sheet in the test host destabilizes its neighbours (docs/NOTES.md ▸
/// Testing).
enum ArchiveWriteBackPlan {
    /// One group per archive, **first-seen order**, each holding its members in the order they were
    /// gathered.
    ///
    /// Order is deliberate on both axes and neither is cosmetic. Between archives it means the
    /// sheets arrive in the order the user's edits did, rather than in whatever order a dictionary
    /// happens to hand back — which would differ run to run for the same edits. Within an archive
    /// it decides which copy of a same-named member wins the rewrite, since `ArchiveWriter.add`
    /// replaces as it goes: last write wins, and "last" has to mean the newest save.
    static func groups(of batch: [PendingArchiveWriteBack]) -> [ArchiveWriteBackGroup] {
        var order: [String] = []
        var byArchive: [String: [PendingArchiveWriteBack]] = [:]
        for item in batch {
            if byArchive[item.archivePath] == nil { order.append(item.archivePath) }
            byArchive[item.archivePath, default: []].append(item)
        }
        return order.map {
            ArchiveWriteBackGroup(archivePath: $0, items: byArchive[$0] ?? [])
        }
    }
}
