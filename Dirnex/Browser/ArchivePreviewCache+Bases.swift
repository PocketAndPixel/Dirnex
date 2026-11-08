import DirnexCore
import Foundation

/// The bases kept for edits of archive members, so a save that finds the member changed inside its
/// archive can offer a three-way merge (PLAN.md §M37 Slice 4).
///
/// The archive's half of `RemoteFileCache+Bases`, by the same rule: **a base is the member's bytes
/// as they were in the archive it names**. It is taken when an edit's watch starts on a copy that
/// still holds what was extracted, with the archive's identity as it was just before that
/// extraction. A merge saved into the copy makes the archive's version it merged the base. And once
/// a rewrite has put the copy into the archive, the copy is finished with, as the write-back's own
/// watch is, so its base goes.
///
/// Bases live under the extraction root, which the launch purge clears, in `Bases`, outside every
/// copy's own folder, which the edit watch watches.
extension ArchivePreviewCache {
    /// Where bases and the archive's versions a merge reads are kept.
    static var basesRoot: URL {
        ArchiveExtractor.temporaryRoot.appendingPathComponent("Bases", isDirectory: true)
    }

    var baseStore: EditBaseStore {
        EditBaseStore(root: Self.basesRoot)
    }

    /// Keep a base for `edit`'s copy as its watch starts, when the copy is an archive member's that
    /// this cache extracted and nothing has written since. A copy with a base keeps it, and a server
    /// file has none here: `RemoteFileCache` keeps those.
    func keepBase(for edit: EditedFile) {
        guard case .archiveMember = edit.destination else { return }
        let key = edit.temporaryURL.standardizedFileURL
        guard memberBases[key] == nil,
              let stamp = extractionStamps[key],
              let archive = stamp.archive,
              let landed = stamp.copy,
              let now = EditedFileRevision.current(ofFileAt: key.path),
              !landed.isSuperseded(by: now),
              let base = baseStore.keep(edit.temporaryURL) else { return }
        memberBases[key] = ArchiveMemberBase(base: base, archive: archive)
    }

    /// The base kept for the copy at `url`, or `nil` when there is none to compare or merge from.
    func memberBase(ofCopy url: URL) -> ArchiveMemberBase? {
        guard let kept = memberBases[url.standardizedFileURL],
              FileManager.default.fileExists(atPath: kept.base.path) else { return nil }
        return kept
    }

    /// The copy at `url` holds a merge with the archive's version kept in `merged`: that is its base
    /// from now on.
    func adoptBase(ofCopy url: URL, _ merged: ArchiveMemberBase) {
        dropBase(ofCopy: url)
        memberBases[url.standardizedFileURL] = merged
    }

    /// Forget the base of the copy at `url`, and remove it.
    func dropBase(ofCopy url: URL) {
        let key = url.standardizedFileURL
        if let kept = memberBases[key] {
            baseStore.discard(kept.base)
        }
        memberBases[key] = nil
    }
}
