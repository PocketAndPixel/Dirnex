import DirnexCore
import Foundation

/// What a copy's own bytes are known to be against the server's (PLAN.md §M34 Slice 4).
struct CopyBase: Equatable {
    /// The copy's own revision when it last held exactly what the server did: as downloaded, or as
    /// last uploaded. `nil` once nothing says so.
    var served: EditedFileRevision?
    /// The bytes a merge of the copy's edit starts from: the server's at the revision the copy is
    /// checked against. `nil` until one is kept.
    var base: URL?
}

/// The bases kept for edits of server files, so a save that finds the server's copy changed can
/// offer a three-way merge (PLAN.md §M34 Slice 4).
///
/// **A base is the server's bytes at the revision its copy is checked against**, and every rule
/// here keeps it so. It is taken when an edit's watch starts on a copy that still holds what was
/// downloaded. After an upload lands, the duplicate the upload sent replaces it, so it is what the
/// server now holds byte for byte, whatever the editor wrote meanwhile. A merge saved into the copy
/// makes the server's version it merged the base. And when the copy's record goes, so does its
/// base: with no revision to stand for, nothing says what it is.
///
/// Bases live under the temp root the launch purge clears, in `Bases`, outside every copy's own
/// folder, which the edit watch watches.
extension RemoteFileCache {
    /// Where bases and the duplicates an upload sends are kept.
    static var basesRoot: URL {
        temporaryRoot.appendingPathComponent("Bases", isDirectory: true)
    }

    var baseStore: EditBaseStore {
        EditBaseStore(root: Self.basesRoot)
    }

    /// Where a save's content check brings the server's bytes down to compare with a base
    /// (`WriteBackContentCheck`). Each download is removed once compared, and the launch purge
    /// clears whatever a crash left.
    static var checksRoot: URL {
        temporaryRoot.appendingPathComponent("Checks", isDirectory: true)
    }

    /// Note that the copy at `url` holds the server's bytes as it stands now: it was just
    /// downloaded.
    func noteServed(_ url: URL) {
        copyBases[url.standardizedFileURL, default: CopyBase()].served =
            EditedFileRevision.current(ofFileAt: url.path)
    }

    /// Whether the copy at `url` still holds what the server did when it was downloaded or last
    /// uploaded: nothing has written it since.
    func isUntouched(_ url: URL) -> Bool {
        guard let served = copyBases[url.standardizedFileURL]?.served,
              let now = EditedFileRevision.current(ofFileAt: url.path) else { return false }
        return !served.isSuperseded(by: now)
    }

    /// The base kept for the copy at `url`, or `nil` when there is none to merge from.
    func base(ofCopy url: URL) -> URL? {
        guard let base = copyBases[url.standardizedFileURL]?.base,
              FileManager.default.fileExists(atPath: base.path) else { return nil }
        return base
    }

    /// Keep a base for `edit`'s copy as its watch starts, when the copy is a server file's and still
    /// holds what was downloaded. A copy with a base keeps it, and an archive member has none: no
    /// merge is offered inside an archive.
    func keepBase(for edit: EditedFile) {
        guard case .remoteFile = edit.destination else { return }
        let url = edit.temporaryURL
        let key = url.standardizedFileURL
        guard copyBases[key]?.base == nil, revision(ofCopy: url) != nil, isUntouched(url),
              let base = baseStore.keep(url) else { return }
        copyBases[key]?.base = base
    }

    /// The copy at `url` holds what an upload sent, so `sent` is its base now and the copy holds the
    /// server's bytes as far as anything knows. With nothing sent, the copy keeps no base.
    func replaceBase(ofCopy url: URL, with sent: URL?) {
        dropBase(ofCopy: url)
        guard let sent else { return }
        copyBases[url.standardizedFileURL] = CopyBase(
            served: EditedFileRevision.current(ofFileAt: sent.path),
            base: sent
        )
    }

    /// The copy at `url` holds a merge with the server's version kept at `theirs`: that is its base
    /// from now on. The copy itself holds the merge rather than the server's bytes.
    func adoptBase(ofCopy url: URL, from theirs: URL) {
        dropBase(ofCopy: url)
        copyBases[url.standardizedFileURL] = CopyBase(served: nil, base: theirs)
    }

    /// Forget what the copy at `url` holds, and remove its base.
    func dropBase(ofCopy url: URL) {
        let key = url.standardizedFileURL
        if let base = copyBases[key]?.base {
            baseStore.discard(base)
        }
        copyBases[key] = nil
    }

    /// Stop handing out the copy of `entry` this cache holds when something has written it, so a
    /// fetch of the server's version downloads one rather than taking an edit for it.
    func setAsideEditedCopy(of entry: FileEntry) {
        guard let held = cachedURL(for: entry), !isUntouched(held) else { return }
        drop(entry.path)
    }
}
