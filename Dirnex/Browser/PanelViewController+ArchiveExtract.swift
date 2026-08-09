import AppKit
import DirnexCore

/// F5 copy-out from inside a browsed archive (PLAN.md §M4 "copy out with F5").
///
/// `CopyEngine` takes one backend for both source and destination, so an archive→local copy
/// can't go straight through it. Instead the marked members are extracted to a temp directory
/// (`ArchiveExtractor`) and the resulting *real* files are handed to the normal copy queue via
/// `submitTransfer` — reusing every bit of its conflict / progress / undo machinery, landing in
/// the other pane exactly like a local copy. Copy only: a read-only archive has no source to
/// remove, so there is no move-out.
///
/// An **encrypted** archive is asked for its passphrase first (PLAN.md §M19). The names in a zip's
/// central directory are never encrypted, so such an archive browses normally and the passphrase is
/// wanted only at the moment bytes are — which is also the only moment the user has any context for
/// the question.
extension PanelViewController {
    /// Extract the marked/cursor members of this archive pane to disk, then copy them into the
    /// other pane's directory. Runs the extraction off-main and, for whatever landed, stats the
    /// files back into local `FileEntry` sources the copy queue understands.
    func beginArchiveExtraction() {
        guard let archivePath = panel.path.backend.archivePath else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }

        let destination = destPane.panel.path
        // The other pane must be a real, writable on-disk folder to receive the extracted files.
        guard destination.backend == .local, destPane.backend.capabilities.contains(.write) else {
            presentOperationFailure(
                message: String(localized: "Can’t extract here"),
                detail: String(localized: "Open a folder on disk in the other panel first.")
            )
            return
        }

        // The encryption question is settled before any work starts, off the one cheap read that
        // answers it (headers only — measured at 3–4 ms for a 600 MB archive).
        guard ArchiveExtractor.needsPassphrase(forArchiveAt: archivePath) else {
            runExtraction(sources: sources, archivePath: archivePath, destination: destination)
            return
        }
        askAndExtract(
            sources: sources,
            archivePath: archivePath,
            destination: destination,
            retrying: false
        )
    }

    /// Prompt, extract, and — if the passphrase was refused — prompt again saying so.
    ///
    /// The retry loop is the whole reason this is a separate function: a wrong passphrase is an
    /// ordinary typo, and answering it with a dead-end error alert would make the user re-select the
    /// files and press F5 again to get another go.
    private func askAndExtract(
        sources: [FileEntry],
        archivePath: String,
        destination: VFSPath,
        retrying: Bool
    ) {
        PassphrasePrompt.ask(
            forItemNamed: (archivePath as NSString).lastPathComponent,
            retrying: retrying,
            over: view.window
        ) { [weak self] passphrase in
            guard let self, let passphrase else { return }
            runExtraction(
                sources: sources,
                archivePath: archivePath,
                destination: destination,
                passphrase: passphrase
            )
        }
    }

    private func runExtraction(
        sources: [FileEntry],
        archivePath: String,
        destination: VFSPath,
        passphrase: ArchivePassphrase? = nil
    ) {
        let innerPaths = sources.map(\.path.path)
        let backend = backend
        Task {
            do {
                let localSources = try await Task.detached(priority: .userInitiated) {
                    () throws -> [FileEntry] in
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: innerPaths,
                        fromArchiveAt: archivePath,
                        passphrase: passphrase
                    )
                    // Stat each extracted file into a local source entry; a member that never
                    // landed — bsdtar couldn't find it, or the reader refused its name as a
                    // traversal attempt — fails its stat and is dropped from the copy.
                    return extraction.extractedPaths.compactMap { try? backend.stat(at: .local($0)) }
                }.value

                guard !localSources.isEmpty else {
                    presentOperationFailure(
                        message: String(localized: "Couldn’t extract the selected items"),
                        detail: String(
                            localized: "The archive may be damaged or the items may be missing."
                        )
                    )
                    return
                }
                submitTransfer(kind: .copy, sources: localSources, destination: destination)
                // Marks are consumed the moment the copy is queued, matching F5/delete; the
                // window re-lists both panes as the job finishes.
                panel.clearSelection()
                reloadEverything()
                focusTable()
            } catch EncryptedArchiveError.incorrectPassphrase {
                // A typo, not a failure worth an alert of its own — ask again, saying so.
                askAndExtract(
                    sources: sources,
                    archivePath: archivePath,
                    destination: destination,
                    retrying: true
                )
            } catch {
                presentOperationFailure(
                    message: String(localized: "Couldn’t extract from the archive"),
                    detail: describe(error)
                )
            }
        }
    }
}
