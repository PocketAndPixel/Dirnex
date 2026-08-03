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
        host?.enqueue(
            FileOperation(
                kind: .checksum(.verify(manifest: manifest.path)),
                sources: [],
                destinationDirectory: panel.path
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

    /// The checksum file the cursor is on, or `nil`.
    ///
    /// Cursor-only, never the marked set: verifying is a question about *one* manifest, and a
    /// marked selection that happens to include two would have to pick one or run both, neither of
    /// which is what the gesture said. Recognized by extension (`ChecksumManifest`), because the
    /// menu has to answer before anything is read.
    private func checksumManifestUnderCursor() -> FileEntry? {
        guard !cursorOnParentRow,
              let entry = panel.currentEntry,
              entry.kind == .file,
              entry.path.backend == .local,
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
                    Checksums are computed from bytes on this Mac, so this works in a folder on \
                    disk. A file on a server has to be downloaded first.
                    """,
                    comment: "Create-checksum failure detail; states the remote limitation."
                )
            )
            return
        }
        let sources = selectionTargets()
        guard !sources.isEmpty else { return }
        presentChecksumSheet(sources: sources)
    }

    /// Whether Create Checksum File should be enabled: a real, writable folder on disk with
    /// something selected.
    ///
    /// Local-only, and that is a stated limitation rather than an oversight — neither `sftp` nor
    /// `curl` can hash server-side, so a remote checksum is a full download and needs a streaming
    /// read neither backend exposes yet (PLAN.md §M14 Slice 2).
    var canCreateChecksumFile: Bool {
        panel.path.backend == .local
            && !isVirtualDirectory
            && backend.capabilities(for: panel.path).contains(.write)
            && !selectionTargets().isEmpty
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
    private func checksumDirectory(for sources: [FileEntry]) -> VFSPath {
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

    /// Enqueue the job, fetching a single pointed-at cloud file's bytes first.
    ///
    /// This is the split PLAN.md §M14 settled and `ByteComparator` already follows: **a file the
    /// user pointed at downloads, a tree sweep refuses.** One selected file is the same explicit
    /// request Enter and F4 answer by downloading, so it goes through the same `CloudDownloadPrompt`
    /// — silent start, a sheet after 400 ms, and a Stop that abandons it. A folder, or several
    /// items, is not something anybody pointed at: those run with the engine's refusal intact and
    /// every placeholder comes back named in the report as "not downloaded".
    private func startChecksumCreate(
        sources: [FileEntry],
        manifest: VFSPath,
        algorithm: ChecksumAlgorithm
    ) {
        let enqueue: () -> Void = { [weak self] in
            guard let self else { return }
            host?.enqueue(
                FileOperation(
                    kind: .checksum(.create(manifest: manifest, algorithm: algorithm)),
                    sources: sources,
                    // The manifest's own directory, so the operation's metadata agrees with where
                    // the file lands — the runner reads `manifest.parent`, not this, but the two
                    // must not disagree.
                    destinationDirectory: manifest.parent ?? panel.path
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
        guard sources.count == 1, sources[0].kind == .file else {
            enqueue()
            return
        }
        CloudDownloadPrompt.materialize(
            sources[0],
            using: backend,
            over: view.window,
            then: enqueue
        )
    }
}
