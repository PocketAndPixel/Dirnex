import AppKit
import DirnexCore

/// Put Back: returning a trashed item to the folder it was deleted from (PLAN.md §M8 restore).
///
/// The hard part is knowing *where* it came from, and macOS does not tell you — probed 2026-07-21,
/// a trashed file's only xattr is `com.apple.provenance`, `mdls` knows nothing, and no
/// `URLResourceKey` spelling answers. The origin exists in exactly one place: the trash directory's
/// own `.DS_Store`, which `DSStoreReader` parses and `TrashPutBack` interprets, both in the tested
/// core. What lives here is the app half — reading those files, moving the items, and saying what
/// couldn't be done.
///
/// Three rules the flow keeps, in the order they bite:
///
/// - **Never overwrite.** The destination is stat'ed first, because `rename(2)` under
///   `moveItem` would silently replace a file that has since been recreated at the original path —
///   destroying the newer copy to restore an older one the user thought they had thrown away.
/// - **Recreate a vanished folder** rather than refusing. Deleting the folder afterwards is
///   ordinary, and "this can never be restored" is a dead end where one `mkdir` chain isn't.
/// - **One failure never abandons the rest**, exactly like Empty Trash: an item with no record is
///   collected and reported by name at the end.
///
/// **Items trashed out of iCloud Drive are that last case, always.** Their trash keeps no
/// `.DS_Store`; the origin rides on the item as `com.apple.clouddocs.private.trash-parent-bookmark`,
/// an opaque `com.apple.CloudDocs/<UUID>/<hash>` provider reference with no path in it (probed
/// 2026-07-21). So they list, they delete, and Put Back says it doesn't know where they came from —
/// which is the truth, and better than a guess at a folder.
extension PanelViewController {
    /// "Put Back" — return the marked items (or the one under the cursor) to where they came from.
    @objc func putBackSelection(_ sender: Any?) {
        let targets = selectionTargets()
        guard isTrashListing, !targets.isEmpty else { return }
        runPutBack(targets)
    }

    /// "Restore All" — put back everything in the merged Trash, after a confirmation naming the
    /// count. It asks for the same reason Empty Trash does: the action reaches items on volumes the
    /// pane may not be showing, and scatters files across the disk in one click. Hidden entries are
    /// not counted and not restored — a trash's dotfiles are Finder's own `.DS_Store` put-back
    /// databases, and restoring one would move the very record the rest of the restore reads from.
    func restoreAllFromTrash() {
        gatherTrash { [weak self] entries, _ in
            guard let self else { return }
            let restorable = entries.filter { !$0.isHidden }
            guard !restorable.isEmpty else {
                presentOperationFailure(
                    message: "The Trash is empty",
                    detail: "There is nothing to put back."
                )
                return
            }
            confirmRestoreAll(count: restorable.count) { [weak self] in
                self?.runPutBack(restorable)
            }
        }
    }

    /// Informational, not critical: unlike Empty Trash this destroys nothing. It asks only because
    /// it is a bulk move the user cannot preview, so the count is the whole content of the sheet.
    private func confirmRestoreAll(count: Int, proceed: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = count == 1
            ? "Put 1 item back?"
            : "Put \(count) items back?"
        alert.informativeText = "Each item returns to the folder it was deleted from."
        alert.addButton(withTitle: "Put Back")
        alert.addButton(withTitle: "Cancel")
        alert.enableEscapeToCancel()

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    /// Move every entry home, off the main thread, then re-list the panes showing the Trash.
    ///
    /// Not journaled for undo: a put-back *is* the undo of a delete, and the way back from it is
    /// the F8 that put the item there in the first place.
    private func runPutBack(_ entries: [FileEntry]) {
        let paths = entries.map(\.path)
        let backend = backend
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> PutBackOutcome in
                var origins = TrashOriginIndex(backend: backend)
                var outcome = PutBackOutcome()
                for path in paths {
                    guard let origin = origins.origin(of: path) else {
                        outcome.unrecorded.append(path)
                        continue
                    }
                    outcome.record(origins.putBack(path, to: origin), for: path)
                }
                return outcome
            }.value

            panel.clearSelection()
            refreshTrashPanes()
            report(outcome)
        }
    }

    /// Say what didn't happen — and only that. A restore that worked is visible in the pane it
    /// emptied and the folder it filled, so a "restored 4 items" sheet would be a click to dismiss
    /// news the user can already see.
    private func report(_ outcome: PutBackOutcome) {
        if !outcome.blocked.isEmpty {
            presentOperationFailure(
                message: outcome.blocked.count == 1
                    ? "“\(outcome.blocked[0].lastComponent)” is already back"
                    : "\(outcome.blocked.count) items are already back",
                detail: "Something with the same name is in the original folder, so it was left in "
                    + "the Trash rather than replaced."
            )
            return
        }
        if !outcome.unrecorded.isEmpty {
            presentOperationFailure(
                message: outcome.unrecorded.count == 1
                    ? "Don’t know where “\(outcome.unrecorded[0].lastComponent)” came from"
                    : "Don’t know where \(outcome.unrecorded.count) items came from",
                detail: "macOS records the original folder when an item is trashed, and there is no "
                    + "record for this one. Drag it out of the Trash instead."
            )
            return
        }
        if let error = outcome.firstError, let path = outcome.failed.first {
            presentOperationFailure(
                message: outcome.failed.count == 1
                    ? "Couldn’t put “\(path.lastComponent)” back"
                    : "Couldn’t put \(outcome.failed.count) items back",
                detail: describe(error)
            )
        }
    }
}

/// Reads each trash directory's `.DS_Store` at most once and answers "where did this come from?"
/// for the items in it.
///
/// Cached per directory because "Restore All" asks for every item at once: without it, a Trash
/// holding 500 items would parse the same 6 KB B-tree 500 times. Keyed by the item's *parent*,
/// which for a merged listing is whichever volume's trash it actually sits in.
private struct TrashOriginIndex {
    let backend: any VFSBackend
    private var indexes: [String: [String: TrashOrigin]] = [:]

    init(backend: any VFSBackend) {
        self.backend = backend
    }

    mutating func origin(of path: VFSPath) -> TrashOrigin? {
        guard let trash = path.parent else { return nil }
        if indexes[trash.path] == nil {
            indexes[trash.path] = Self.readOrigins(inTrashAt: trash)
        }
        return indexes[trash.path]?[path.lastComponent]
    }

    /// Read and parse one trash's put-back database, or an empty map when it has none — a trash
    /// that has never been opened in Finder has no `.DS_Store` at all, and neither a missing file
    /// nor an unreadable one is worth failing a restore over: both mean "no record", which the
    /// caller already reports per item.
    private static func readOrigins(inTrashAt trash: VFSPath) -> [String: TrashOrigin] {
        let store = trash.appending(".DS_Store")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: store.path)),
              let origins = try? TrashPutBack.origins(inDSStore: data, ofTrashAt: trash)
        else {
            return [:]
        }
        return origins
    }

    /// Move one item home, recreating the folder it came from if that has since been deleted.
    func putBack(_ path: VFSPath, to origin: TrashOrigin) -> PutBackResult {
        // Checked, not left to `rename(2)`, which would replace whatever is there — see the note on
        // the extension. The gap between this stat and the move is a race no filesystem call closes
        // for a cross-directory rename; losing it needs the same name to appear in that folder in
        // the same millisecond the user chose Put Back.
        if (try? backend.stat(at: origin.destination)) != nil { return .blocked }
        do {
            try backend.moveItem(at: path, to: origin.destination)
            return .restored
        } catch VFSError.notFound {
            // The original folder is gone. Rebuild the chain and try once more — the second failure
            // is reported rather than retried.
            createDirectories(upTo: origin.directory)
            do {
                try backend.moveItem(at: path, to: origin.destination)
                return .restored
            } catch {
                return .failed(error)
            }
        } catch {
            return .failed(error)
        }
    }

    /// `mkdir -p`: the backend's `createDirectory` is a single `mkdir`, so the ancestors are walked
    /// root-first and each failure ignored — the one that matters is the move that follows.
    private func createDirectories(upTo directory: VFSPath) {
        for ancestor in directory.ancestorsFromRoot {
            try? backend.createDirectory(at: ancestor)
        }
    }
}

private enum PutBackResult {
    case restored
    /// Something already occupies the original path, so the item stayed in the Trash.
    case blocked
    case failed(any Error)
}

/// What one restore pass produced, in the order the report prefers to talk about: a collision is
/// the user's file being protected and is worth naming first, then items nothing is known about,
/// then real errors.
private struct PutBackOutcome: Sendable {
    var restored = 0
    var blocked: [VFSPath] = []
    var unrecorded: [VFSPath] = []
    var failed: [VFSPath] = []
    var firstError: (any Error)?

    mutating func record(_ result: PutBackResult, for path: VFSPath) {
        switch result {
        case .restored:
            restored += 1
        case .blocked:
            blocked.append(path)
        case let .failed(error):
            failed.append(path)
            firstError = firstError ?? error
        }
    }
}
