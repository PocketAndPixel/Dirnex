import AppKit
import DirnexCore

/// Verify Checksums and Create Checksum File (PLAN.md §M14 Slice 2) — the pane's half of the
/// checksum pair.
///
/// Every byte is hashed by the tested `DirnexCore.ChecksumRunner`, on the window's shared
/// `FileOperationQueue`. This file decides only *which* files and *which* manifest, raises the two
/// sheets, and hands the job over; the answer comes back through the queue's snapshot stream, where
/// `BrowserWindowController+Checksum` presents it. Nothing here blocks: a 50 GB SHA-256 is ~25 s
/// and a CRC32 of the same file ~100 s, which is exactly what the queue exists for.
extension PanelViewController {
    // MARK: - Verify (menu / palette action, dispatched to the focused pane)

    @objc func verifyChecksums(_ sender: Any?) {
        guard let manifest = checksumManifestUnderCursor() else {
            presentOperationFailure(
                message: String(
                    localized: "No checksum file selected",
                    comment: "Verify-checksums failure title when the cursor isn't on a manifest."
                ),
                detail: String(
                    localized: """
                    Put the cursor on a checksum file — one ending in .sha256, .sha1, .md5, .sfv \
                    or .crc — and verify it.
                    """,
                    comment: "Verify-checksums failure detail listing the recognized extensions."
                )
            )
            return
        }
        // A manifest on this disk names files on this disk: the walk is rooted at its own parent, so
        // nothing can need fetching and nothing has to be worked out first. Byte-identical to what
        // M14 shipped, which is what keeps the ordinary case free of the two-phase gesture below —
        // and free of its second directory walk.
        guard manifest.path.backend != .local else {
            enqueueVerification(of: manifest, materialized: MaterializedPaths())
            return
        }
        // Phase one: the manifest itself. It is a few kilobytes, so it is under every row of the
        // size table and asks nothing — which is what makes two phases affordable at all.
        materialize([manifest], for: .checksum, includingPlaceholders: true) {
            Self.verifyFailureMessage(manifest)
        } then: { [weak self] _ in
            self?.planVerification(of: manifest)
        }
    }

    /// Phase two: read the manifest that has just landed, work out what it claims, and bring *that*
    /// down before queueing.
    ///
    /// **Two phases, because nothing can know what to fetch until the manifest has been read.** The
    /// walk between them costs listings and no transfers, which is what makes the shape affordable:
    /// by the time anything is downloaded the set is known exactly, so the one confirmation the user
    /// sees names the real total rather than a floor.
    ///
    /// It resolves the set through the very function the run will use
    /// (``DirnexCore/ChecksumVerifyScope``) rather than a second walk written here. A file this half
    /// failed to predict would come back "not downloaded" while sitting right in front of the user,
    /// and two spellings of "which files does this manifest claim" is the drift this project keeps
    /// paying for.
    private func planVerification(of manifest: FileEntry) {
        let manifestPaths = materializedPaths(for: [manifest])
        guard let local = manifestPaths.localPath(for: manifest.path) else { return }
        let backend = backend
        Task { [weak self] in
            let outcome = await BlockingWork.run {
                Result {
                    try ChecksumVerifyScope.resolve(
                        manifestAt: manifest.path,
                        contents: try Data(contentsOf: URL(fileURLWithPath: local.path)),
                        // An unlistable subdirectory is skipped rather than fatal, exactly as the
                        // run's own walk treats it: what was found elsewhere is still an answer.
                        list: { (try? backend.listDirectory(at: $0)) ?? [] }
                    )
                }
            }
            guard let self else { return }
            switch outcome {
            case let .success(scope):
                fetchClaimed(scope, of: manifest, manifestPaths: manifestPaths)
            case let .failure(error):
                presentVerifyPlanFailure(error, manifest: manifest)
            }
        }
    }

    /// Bring down every file the manifest claims, then queue the verification over the lot.
    private func fetchClaimed(
        _ scope: ChecksumVerifyScope,
        of manifest: FileEntry,
        manifestPaths: MaterializedPaths
    ) {
        let claimed = scope.claimed.map(\.entry)
        // A manifest naming nothing that is actually there still has a verdict — every line
        // `missing` — and `materialize` returns without calling back on an empty set, so this has to
        // be answered here rather than fallen through.
        guard !claimed.isEmpty else {
            enqueueVerification(of: manifest, materialized: manifestPaths)
            return
        }
        materialize(claimed, for: .checksum, includingPlaceholders: true) {
            Self.verifyFailureMessage(manifest)
        } then: { [weak self] _ in
            guard let self else { return }
            enqueueVerification(
                of: manifest,
                materialized: manifestPaths.merging(materializedPaths(for: claimed))
            )
        }
    }

    /// Hand the job to the queue. The manifest keeps naming its **own** path throughout — that is
    /// what makes the run's root the remote directory and every name in the report the server's own
    /// spelling — while `materialized` is where the bytes are.
    private func enqueueVerification(of manifest: FileEntry, materialized: MaterializedPaths) {
        host?.enqueue(
            FileOperation(
                kind: .checksum(.verify(manifest: manifest.path)),
                sources: [],
                destinationDirectory: manifest.path.parent ?? panel.path,
                materialized: materialized
            ),
            conflictPolicy: .fail,
            resolveConflict: nil,
            onError: nil
        )
        showTransientStatus(
            String(
                localized: "Verifying “\(manifest.name)”…",
                comment: "Status while a checksum file is being verified; %@ is its name."
            )
        )
    }

    /// One wording for both phases: from the user's side, "the manifest wouldn't come down" and
    /// "the files it names wouldn't" are the same disappointment about the same gesture.
    private static func verifyFailureMessage(_ manifest: FileEntry) -> String {
        String(
            localized: "Couldn’t verify “\(manifest.name)”",
            comment: """
            Alert title when a checksum file or the files it names can't be downloaded for \
            verification; %@ is the checksum file's name.
            """
        )
    }

    /// The manifest came down and could not be read as one — the job's own failure, reported here
    /// because nothing was ever queued to report it. Worded by the catalog rather than by the core's
    /// English, for the reason every `ChecksumError` is (it reaches the screen through a return
    /// value, where a literal would render English under a translated title).
    private func presentVerifyPlanFailure(_ error: any Error, manifest: FileEntry) {
        presentOperationFailure(
            message: Self.verifyFailureMessage(manifest),
            detail: (error as? ChecksumError).map(LocalizedCatalog.sentence(for:)) ?? describe(error)
        )
    }

    /// The checksum file the cursor is on, or `nil`.
    ///
    /// Cursor-only, never the marked set: verifying is a question about *one* manifest, and a
    /// marked selection that happens to include two would have to pick one or run both, neither of
    /// which is what the gesture said. Recognized by extension (`ChecksumManifest`), because the
    /// menu has to answer before anything is read — which is also what makes a manifest on a server
    /// answerable at all, since the name is the only thing a listing carries.
    ///
    /// The `backend == .local` this used to require is gone (M24 Slice 4): a manifest sitting beside
    /// a bucket's objects is the ordinary reason to have one there.
    private func checksumManifestUnderCursor() -> FileEntry? {
        guard !cursorOnParentRow,
              let entry = panel.currentEntry,
              entry.kind == .file,
              ChecksumManifest.isManifestFileName(entry.name) else { return nil }
        return entry
    }

    /// Whether Verify Checksums should be enabled.
    var canVerifyChecksums: Bool { checksumManifestUnderCursor() != nil }

    // MARK: - Create (menu / palette action)

    @objc func createChecksumFile(_ sender: Any?) {
        guard canCreateChecksumFile else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t create a checksum file here",
                    comment: "Create-checksum failure title: the pane isn't a writable local folder."
                ),
                detail: String(
                    localized: """
                    The checksum file has to be written beside the items it describes, so this \
                    needs somewhere that can be written to.
                    """,
                    comment: """
                    Create-checksum failure detail: the manifest's own directory is read-only or \
                    is a virtual listing with no directory of its own.
                    """
                )
            )
            return
        }
        let sources = selectionTargets()
        guard !sources.isEmpty else { return }
        // A folder that is not already on this disk is not one transfer and not one extraction: it
        // stands for an unknown number of objects in an unknown number of requests, which is why
        // `MaterializationPlan` names those rows rather than weighing them. The hand-off refuses
        // them for the same reason and in the same words; bringing a whole remote tree down to hash
        // it is F5 followed by this gesture, and both halves of that are already here.
        guard let folder = materializationPlan(for: sources).pendingDirectories.first else {
            presentChecksumSheet(sources: sources)
            return
        }
        presentOperationFailure(
            message: String(
                localized: "Can’t checksum a folder that isn’t on this Mac",
                comment: """
                Create-checksum failure title when a selected folder is on a server or in an \
                archive.
                """
            ),
            detail: String(
                localized: """
                “\(folder.name)” would have to be downloaded in full first, and there is no \
                way to tell in advance how much that is. Copy it over with F5 and checksum the copy.
                """,
                comment: """
                Create-checksum failure detail; %@ is the folder's name. F5 is the copy key.
                """
            )
        )
    }

    /// Whether Create Checksum File should be enabled: something selected, and somewhere writable
    /// to put the manifest.
    ///
    /// **The question is about the manifest's own directory, not the pane's** (M24 Slice 4). Every
    /// checksum format spells its names relative to the file's own location, so a manifest goes
    /// beside the objects it describes — which for a bucket's objects is the bucket, and is an
    /// upload. `capabilities(for:)` is already the right question asked of the right path: a
    /// writable bucket says yes, a read-only one says no, and a browsed archive says no on its own
    /// because `ArchiveBackend` advertises `.read` alone.
    ///
    /// A tree selection is why it asks about ``checksumDirectory(for:)`` rather than `panel.path`:
    /// those two are the same folder in a flat listing and need not be in a tree, and the one the
    /// write will actually reach is the one worth gating on.
    var canCreateChecksumFile: Bool {
        let sources = selectionTargets()
        guard !sources.isEmpty, !isVirtualDirectory else { return false }
        return backend.capabilities(for: checksumDirectory(for: sources)).contains(.write)
    }

    // MARK: - The create sheet

    private func presentChecksumSheet(sources: [FileEntry]) {
        let alert = NSAlert()
        alert.messageText = sources.count == 1
            ? String(
                localized: "Create a checksum file for “\(sources[0].name)”",
                comment: "Create-checksum sheet title for one item; %@ is its name."
            )
            : String(
                localized: "Create a checksum file for \(sources.count) items",
                comment: "Create-checksum sheet title for several items; %lld is the count. Plural."
            )
        alert.informativeText = String(
            localized: """
            The file is written into “\(checksumDirectory(for: sources).lastComponent)”, beside the \
            items it describes.
            """,
            comment: "Create-checksum sheet body; %@ is the folder name."
        )
        alert.addButton(withTitle: String(
            localized: "Create",
            comment: "Confirm button of the create-checksum sheet."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()

        let accessory = ChecksumAccessory(baseName: defaultChecksumBaseName(for: sources))
        alert.accessoryView = accessory.view
        alert.window.initialFirstResponder = accessory.nameField

        // `accessory` is captured (and so kept alive) by this closure for the sheet's lifetime,
        // which is what keeps the algorithm popup's target from being deallocated under it:
        // `NSControl.target` is weak.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.confirmAndCreate(
                sources: sources,
                fileName: accessory.manifestFileName,
                algorithm: accessory.algorithm
            )
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            accessory.nameField.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// The name the sheet pre-fills: the item's own name for a single selection, the folder's for
    /// several — so one file yields `disk.iso.sha256`, the form every publisher ships, and a
    /// multi-selection yields `Downloads.sha256`.
    ///
    /// The folder used for the multi case is where the manifest actually lands
    /// (``checksumDirectory(for:)``), not the pane's root, so a tree selection sitting inside `raw/`
    /// is named `raw.sha256` after the folder it is in rather than after the whole tree.
    private func defaultChecksumBaseName(for sources: [FileEntry]) -> String {
        sources.count == 1 ? sources[0].name : checksumDirectory(for: sources).lastComponent
    }

    /// The directory a created manifest belongs in — beside the selected objects, at their common
    /// root. In a flat listing that is the pane's own folder (unchanged); in a tree it is wherever
    /// the selection actually lives, so the checksum file sits with the files it names rather than
    /// up at the tree's root. Falls back to the pane's directory for the empty/mixed-backend cases
    /// the create action has already excluded.
    func checksumDirectory(for sources: [FileEntry]) -> VFSPath {
        ChecksumScope.manifestDirectory(for: sources.map(\.path)) ?? panel.path
    }

    // MARK: - Conflict + enqueue

    /// Guard an existing file at the target — the run would replace it — then enqueue.
    private func confirmAndCreate(
        sources: [FileEntry],
        fileName: String,
        algorithm: ChecksumAlgorithm
    ) {
        let target = checksumDirectory(for: sources).appending(fileName)
        guard (try? backend.stat(at: target)) != nil else {
            startChecksumCreate(sources: sources, manifest: target, algorithm: algorithm)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "“\(fileName)” already exists",
            comment: "Create-checksum overwrite title; %@ is the checksum file's name."
        )
        alert.informativeText = String(
            localized: "Replace the existing checksum file?",
            comment: "Create-checksum overwrite body."
        )
        alert.addButton(withTitle: String(
            localized: "Replace",
            comment: "Button that overwrites an existing file."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        let proceed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.startChecksumCreate(sources: sources, manifest: target, algorithm: algorithm)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }

    /// Bring the marked set down to real paths, then enqueue.
    ///
    /// **The split PLAN.md §M14 settled still holds, widened to the set the user actually marked**
    /// (M24 Slice 4): *a file somebody pointed at downloads, a tree sweep refuses*. Marking is
    /// pointing, so every marked row is fetched — where before only a lone selected file was — while
    /// a file the runner *discovers* by descending into a marked folder is in no plan and reaches
    /// the engine's own refusal, coming back named in the report as "not downloaded". That is the
    /// same line, drawn where the gesture is rather than where the count is.
    ///
    /// The map is built from ``materializedPaths(for:)`` rather than from the transfer's report,
    /// because a row an earlier preview already downloaded is just as readable and was never
    /// re-fetched. Every name in the manifest is still the row's own — the engine is handed a temp
    /// copy and nothing else about the row (``DirnexCore/MaterializedPaths``).
    /// Internal rather than private so `ChecksumMaterializeTests` can drive the hand-over itself —
    /// what the gesture *queues* is the whole of this slice on the app's side, and the sheet in
    /// front of it is not what any of those claims are about.
    func startChecksumCreate(
        sources: [FileEntry],
        manifest: VFSPath,
        algorithm: ChecksumAlgorithm
    ) {
        materialize(sources, for: .checksum, includingPlaceholders: true) {
            String(
                localized: "Couldn’t compute these checksums",
                comment: """
                Alert title when the selected items can't be downloaded or extracted for hashing.
                """
            )
        } then: { [weak self] _ in
            guard let self else { return }
            host?.enqueue(
                FileOperation(
                    kind: .checksum(.create(manifest: manifest, algorithm: algorithm)),
                    sources: sources,
                    // The manifest's own directory, so the operation's metadata agrees with where
                    // the file lands — the runner reads `manifest.parent`, not this, but the two
                    // must not disagree.
                    destinationDirectory: manifest.parent ?? panel.path,
                    materialized: materializedPaths(for: sources)
                ),
                conflictPolicy: .fail,
                resolveConflict: nil,
                onError: nil
            )
            showTransientStatus(
                String(
                    localized: "Computing \(algorithm.displayName) checksums…",
                    comment: "Status while checksums are being computed; %@ is the algorithm name."
                )
            )
        }
    }
}
