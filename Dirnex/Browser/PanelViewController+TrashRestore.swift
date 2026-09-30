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
/// **There is a second source, and it answers only where the first is silent** (PLAN.md §M26
/// Slice 4). ``ProviderAwareTrashPerformer`` moves an item inside a File Provider domain with a
/// `renamex_np` of ours, which cannot write the `ptbL`/`ptbN` pair — so M26 would otherwise have
/// left every Dropbox, OneDrive, Box, Drive and iCloud delete with no way home. ``TrashOriginStore``
/// keeps the origin the delete already knew, and ``TrashOriginRecords/origin(of:finderRecord:)``
/// merges the two with **Finder's record winning wherever it exists**: an ordinary local delete
/// still goes through `trashItem`, and two sources answering one question is exactly what must not
/// happen.
///
/// **That closes iCloud's own gap for Dirnex's deletes, and only for those.** Its trash keeps no
/// `.DS_Store` at all; the origin rides on the item as
/// `com.apple.clouddocs.private.trash-parent-bookmark`, an opaque `com.apple.CloudDocs/<UUID>/<hash>`
/// provider reference with no path in it (probed 2026-07-21), so an item **Finder** trashed there is
/// still the last case above — as is anything trashed before the store shipped, and anything Finder
/// deleted out of a provider domain (on Box that does not land on this Mac at all, it goes to Box's
/// server-side trash). All of those keep the honest answer: Put Back says it doesn't know where the
/// item came from, which is the truth and better than a guess at a folder.
extension PanelViewController {
    /// The rows a Put Back would act on, or nothing where the gesture does not apply.
    ///
    /// One funnel for the action *and* the menu validator. This codebase has been bitten often
    /// enough to make that worth a property rather than two `if`s: a "can this apply here" rule
    /// spelled twice drifts, and it is the validator half that drifts, so the command goes gray
    /// over a row the action would have handled perfectly (docs/NOTES.md).
    ///
    /// **The two sources are asked different questions on purpose.** The merged Trash is a question
    /// about the *pane* — its rows carry real paths spread across every volume's trash, and what
    /// makes them restorable is the `trash:` listing they arrived in. A share's `#recycle` is a
    /// question about the *row*: that pane is an ordinary directory listing, and in a tree a bin's
    /// contents can sit beside rows that are in no bin at all.
    var putBackTargets: [FileEntry] {
        let targets = selectionTargets()
        guard !targets.isEmpty else { return [] }
        if isTrashListing { return targets }
        // Every target, not any: a mixed tree selection would otherwise restore the rows it could
        // and report the rest as failures the user never asked for.
        return targets.allSatisfy { ShareRecycleBin.holds($0.path) } ? targets : []
    }

    /// "Put Back" — return the marked items (or the one under the cursor) to where they came from.
    @objc func putBackSelection(_ sender: Any?) {
        let targets = putBackTargets
        guard !targets.isEmpty else { return }
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
                    message: String(
                        localized: "The Trash is empty",
                        comment: "Shown when Put Back is invoked but nothing is there."
                    ),
                    detail: String(
                        localized: "There is nothing to put back.",
                        comment: "Put-Back detail when the Trash is already empty."
                    )
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
        alert.messageText = String(localized: "Put \(count) items back?")
        alert.informativeText = String(
            localized: "Each item returns to the folder it was deleted from.",
            comment: "Restore-All confirmation body."
        )
        alert.addButton(
            withTitle: String(
                localized: "Put Back",
                comment: "Confirm button on the Restore All confirmation."
            )
        )
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
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
        // Taken here, on the main actor: the store is a `@MainActor` object and its records are a
        // `Sendable` value, which is what lets the matching below run off the main thread.
        let recorded = TrashOriginStore.shared.snapshot
        Task {
            let outcome = await BlockingWork.run { () -> PutBackOutcome in
                var origins = TrashOriginIndex(backend: backend, recorded: recorded)
                var outcome = PutBackOutcome()
                for path in paths {
                    guard let origin = origins.origin(of: path) else {
                        outcome.unrecorded.append(path)
                        continue
                    }
                    outcome.record(origins.putBack(path, to: origin), for: path, origin: origin)
                }
                return outcome
            }

            panel.clearSelection()
            refreshTrashPanes()
            refreshPanes(showing: outcome.touched)
            report(outcome)
        }
    }

    /// Re-list what is on screen that the restore changed: the bin the items left, and the folders
    /// they landed in. ``refreshTrashPanes()`` above covers the merged Trash, which is a *listing*
    /// rather than a directory and so answers to none of these paths — and a `#recycle` pane is the
    /// mirror image, an ordinary directory that `refreshTrashPanes` will never touch. Without this
    /// the bin goes on drawing the row it no longer holds (docs/NOTES.md, "which pane do I
    /// re-list").
    private func refreshPanes(showing directories: Set<VFSPath>) {
        guard !directories.isEmpty else { return }
        for pane in [self, host?.panelCounterpart(of: self)].compactMap({ $0 })
            where !pane.isTrashListing && directories.contains(where: pane.isShowing) {
            pane.refreshCurrentDirectory()
        }
    }

    /// Say what didn't happen — and only that. A restore that worked is visible in the pane it
    /// emptied and the folder it filled, so a "restored 4 items" sheet would be a click to dismiss
    /// news the user can already see.
    private func report(_ outcome: PutBackOutcome) {
        if !outcome.blocked.isEmpty {
            presentOperationFailure(
                message: outcome.blocked.count == 1
                    ? String(
                        localized: "“\(outcome.blocked[0].lastComponent)” is already back",
                        comment: "Put-Back result: this item's name already exists at its origin; %@ is the item name."
                    )
                    : String(
                        localized: "\(outcome.blocked.count) items are already back",
                        comment: "Put-Back result for several blocked items; %lld is the count."
                    ),
                detail: String(
                    localized: """
                    Something with the same name is in the original folder, so it was left in \
                    the Trash rather than replaced.
                    """,
                    comment: "Put-Back detail: a name collision blocked the restore."
                )
            )
            return
        }
        if !outcome.unrecorded.isEmpty {
            presentOperationFailure(
                message: outcome.unrecorded.count == 1
                    ? String(
                        localized: "Don’t know where “\(outcome.unrecorded[0].lastComponent)” came from",
                        comment: "Put-Back result for one item with no recorded origin; %@ is the item name."
                    )
                    : String(
                        localized: "Don’t know where \(outcome.unrecorded.count) items came from",
                        comment: "Put-Back result for several items with no recorded origin; %lld is the count."
                    ),
                detail: String(
                    localized: """
                    macOS records the original folder when an item is trashed, and there is no \
                    record for this one. Drag it out of the Trash instead.
                    """,
                    comment: "Put-Back detail: no recorded origin folder."
                )
            )
            return
        }
        if let error = outcome.firstError, let path = outcome.failed.first {
            presentOperationFailure(
                message: outcome.failed.count == 1
                    ? String(
                        localized: "Couldn’t put “\(path.lastComponent)” back",
                        comment: "Put-Back failure for one item; %@ is the item name."
                    )
                    : String(
                        localized: "Couldn’t put \(outcome.failed.count) items back",
                        comment: "Put-Back failure for several items; %lld is the count."
                    ),
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
/// Internal rather than private so the merge can be driven directly in a test: it is the one place
/// the two sources of a put-back origin meet, and a wiring that quietly stopped consulting the
/// store would be invisible everywhere else (the "an opt-in seam whose default is *do it the old
/// way*" family in docs/NOTES.md).
struct TrashOriginIndex {
    let backend: any VFSBackend
    /// What Dirnex recorded for its own deletes — consulted only where the `.DS_Store` is silent
    /// (``TrashOriginRecords``).
    let recorded: TrashOriginRecords
    private var indexes: [String: [String: TrashOrigin]] = [:]

    init(backend: any VFSBackend, recorded: TrashOriginRecords) {
        self.backend = backend
        self.recorded = recorded
    }

    /// **Finder's record wins wherever it exists**, and the direction is the whole correctness
    /// argument: an ordinary local delete still goes through `trashItem`, which writes the
    /// `ptbL`/`ptbN` pair, so the common case must keep answering from the `.DS_Store` — otherwise
    /// Dirnex's Put Back and Finder's own could send one file to two different folders. The merge
    /// itself lives in the core value, where a test can fail on it being inverted.
    mutating func origin(of path: VFSPath) -> TrashOrigin? {
        // A network share's own `#recycle` answers first, and answers alone. It is not a third
        // opinion about one item: the mirroring is **structural** — where the file came from is
        // where it physically sits, measured 2026-09-20 against a live DSM share — where both
        // sources below are records somebody wrote, and a `#recycle` has neither. Asked after them
        // it would still be right; asked first it cannot be overruled by a `.DS_Store` that found
        // its way into a bin, which is the "two sources answering one question" rule this type
        // exists to keep.
        if let mirrored = ShareRecycleBin.origin(of: path) { return mirrored }
        guard let trash = path.parent else { return nil }
        if indexes[trash.path] == nil {
            indexes[trash.path] = Self.readOrigins(inTrashAt: trash)
        }
        return recorded.origin(of: path, finderRecord: indexes[trash.path]?[path.lastComponent])
    }

    /// Read and parse one trash's put-back database, or an empty map when it has none — a trash
    /// that has never been opened in Finder has no `.DS_Store` at all, and neither a missing file
    /// nor an unreadable one is worth failing a restore over: both mean "no record", which the
    /// caller already reports per item.
    private static func readOrigins(inTrashAt trash: VFSPath) -> [String: TrashOrigin] {
        let store = trash.appending(TrashPutBack.storeName)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: store.path)),
              let origins = try? TrashPutBack.origins(inDSStore: data, ofTrashAt: trash)
        else {
            return [:]
        }
        return origins
    }

    /// Move one item home, recreating the folder it came from if that has since been deleted.
    ///
    /// Internal, like ``origin(of:)``, because a share's `#recycle` gave this function rules of its
    /// own worth failing on: the scaffolding prune below, and the two inherited rules (never
    /// overwrite, recreate a vanished folder) meeting a bin for the first time. It still answers in
    /// this file's vocabulary, so ``PutBackResult`` travels with it.
    func putBack(_ path: VFSPath, to origin: TrashOrigin) -> PutBackResult {
        // Checked, not left to `rename(2)`, which would replace whatever is there — see the note on
        // the extension. The gap between this stat and the move is a race no filesystem call closes
        // for a cross-directory rename; losing it needs the same name to appear in that folder in
        // the same millisecond the user chose Put Back.
        if (try? backend.stat(at: origin.destination)) != nil { return .blocked }
        do {
            try backend.moveItem(at: path, to: origin.destination)
            return restored(after: path)
        } catch VFSError.notFound {
            // The original folder is gone. Rebuild the chain and try once more — the second failure
            // is reported rather than retried.
            createDirectories(upTo: origin.directory)
            do {
                try backend.moveItem(at: path, to: origin.destination)
                return restored(after: path)
            } catch {
                return .failed(error)
            }
        } catch {
            return .failed(error)
        }
    }

    /// A restore that landed, plus the tidying only a `#recycle` needs.
    private func restored(after path: VFSPath) -> PutBackResult {
        pruneEmptyBinFolders(above: path)
        return .restored
    }

    /// Remove the empty mirror folders a restore leaves standing in a share's `#recycle`.
    ///
    /// The bin reproduces an item's original path as **real directories**, so putting
    /// `#recycle/probe/sub/nested.txt` back leaves `#recycle/probe/sub` behind — scaffolding for a
    /// file that is no longer in it, piling up in the one folder a user opens to see what they
    /// deleted. Measured on a live DSM share 2026-09-20. It is the exact inverse of
    /// ``createDirectories(upTo:)``, and a macOS trash needs none of it: items there sit at the
    /// trash's own root, so ``ShareRecycleBin/binRoot(of:)`` answers `nil` and this returns at once.
    ///
    /// **`rmdir` semantics, deliberately.** Each directory is listed and removed only while it is
    /// empty, so a sibling still waiting to be restored can never be swept up with it — the backend's
    /// `removeItem` is recursive, and the listing is what stands between it and somebody's files. The
    /// walk stops **at** the bin, because one level further is the share's own folders. Every failure
    /// is ignored: the restore has already happened, and leftover scaffolding is not worth turning a
    /// successful Put Back into a reported one.
    private func pruneEmptyBinFolders(above path: VFSPath) {
        guard let bin = ShareRecycleBin.binRoot(of: path) else { return }
        var directory = path.parent
        while let current = directory, current != bin, current.isSelfOrDescendant(of: bin) {
            guard let contents = try? backend.listDirectory(at: current), contents.isEmpty else {
                return
            }
            try? backend.removeItem(at: current)
            directory = current.parent
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

/// Internal rather than private so ``TrashOriginIndex/putBack(_:to:)`` can be reached from a test —
/// a result type is not worth hiding at the cost of the function that returns it.
enum PutBackResult {
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
    /// The directories a restore changed — the folder each item landed in, and the one it left.
    /// Only the panes drawing these are re-listed.
    var touched: Set<VFSPath> = []

    mutating func record(_ result: PutBackResult, for path: VFSPath, origin: TrashOrigin) {
        switch result {
        case .restored:
            restored += 1
            touched.insert(origin.directory)
            if let source = path.parent { touched.insert(source) }
        case .blocked:
            blocked.append(path)
        case let .failed(error):
            failed.append(path)
            firstError = firstError ?? error
        }
    }
}
