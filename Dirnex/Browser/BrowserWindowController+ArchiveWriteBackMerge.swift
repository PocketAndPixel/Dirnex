import AppKit
import DirnexCore

/// Merge… in the archive's question (PLAN.md §M37 Slice 4): a member changed inside its archive
/// under an edit merges the two edits instead of losing one.
///
/// The server entry's shape (`+WriteBackMerge`), with the archive in the server's place. The three
/// versions are the base kept for the copy (`ArchivePreviewCache+Bases`), the copy the editor saved,
/// and the member as the archive holds it now, read again when Merge… is pressed. The merge window
/// writes its result into the editor's copy, which then takes that version as its base and goes back
/// into the archive as any save of it does, through the archive's own question and rewrite.
extension BrowserWindowController {
    /// Read the archive's version of `item` again and open the merge window on it, the base and the
    /// copy. Reports what stops it on `host`, and writes nothing back: the window's save does.
    func mergeArchiveMember(_ item: PendingArchiveWriteBack, over host: NSWindow?) async {
        let copy = item.edit.temporaryURL
        let name = item.edit.name
        // One merge per copy, as for a server file.
        let earlier = MergeWindowController.open.first { $0.input.target.path == copy.path }
        if let earlier, earlier.hasUnsavedChoices {
            earlier.showWindow(nil)
            return
        }
        guard let base = archivePreviewCache.memberBase(ofCopy: copy) else {
            return presentMergeFailure(name, detail: Self.archiveMergeNoBaseDetail, over: host)
        }
        guard let theirs = await readArchiveVersion(of: item, over: host) else { return }
        let store = archivePreviewCache.baseStore
        let size = EditedFileRevision.current(ofFileAt: theirs.base.path)?.byteSize ?? -1
        guard Self.mergeReads(byteSize: size) else {
            store.discard(theirs.base)
            return presentMergeFailure(
                name,
                detail: CompareOpener.limitDetail(ByteComparator.prescanByteLimit),
                over: host
            )
        }
        let read = await BlockingWork.run {
            Self.readMerge(base: base.base, yours: copy, theirs: theirs.base)
        }
        switch read {
        case let .success(documents):
            earlier?.close()
            presentArchiveMerge(item, documents, theirs: theirs)
        case let .failure(failure):
            store.discard(theirs.base)
            presentMergeFailure(name, detail: CompareOpener.failureDetail(failure), over: host)
        }
    }

    /// The member as the archive holds it now, kept in the base store with the archive's identity
    /// as it was before the read, or `nil` when it could not be read, which is reported.
    ///
    /// Through the focused pane's passphrase funnel, since Merge… is pressed: an encrypted archive
    /// nobody has unlocked asks here, where the check that offered Merge… would not have.
    private func readArchiveVersion(
        of item: PendingArchiveWriteBack,
        over host: NSWindow?
    ) async -> ArchiveMemberBase? {
        let pane = focusedPanel
        let store = archivePreviewCache.baseStore
        let innerPath = item.innerPath
        return await withCheckedContinuation { continuation in
            pane.withArchivePassphrase(forArchiveAt: item.archivePath) { [weak self] passphrase in
                guard let check = self?.archiveMemberCheck(
                    for: item.archivePath,
                    passphrase: passphrase
                )
                else { throw CancellationError() }
                return try await BlockingWork.run {
                    Result { try check.keep(innerPath, in: store) }
                }.get()
            } onSuccess: { kept in
                continuation.resume(returning: kept)
            } onFailure: { [weak self] error in
                self?.presentMergeFailure(item.edit.name, detail: pane.describe(error), over: host)
                continuation.resume(returning: nil)
            } onCancel: {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Open the window on the three versions. Its save writes the result into the copy, makes the
    /// archive's version kept in `theirs` the copy's base, then carries the copy back as any save of
    /// it is.
    private func presentArchiveMerge(
        _ item: PendingArchiveWriteBack,
        _ documents: MergeDocuments,
        theirs: ArchiveMemberBase
    ) {
        let name = item.edit.name
        let opening = documents.yours.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
        let input = MergeInput(
            name: name,
            base: MergeVersion(detail: Self.mergeBaseDetail, document: documents.base),
            yours: MergeVersion(detail: Self.mergeYoursDetail, document: documents.yours),
            theirs: MergeVersion(detail: Self.archiveMergeTheirsDetail, document: documents.theirs),
            target: documents.target,
            resultDetail: Self.archiveMergeResultDetail(
                (item.archivePath as NSString).lastPathComponent
            ),
            language: SyntaxLanguage.forFile(named: name, text: opening)
        )
        let saving = Self.archiveMergeSaving(
            item.edit,
            theirs: theirs,
            cache: archivePreviewCache
        ) { [weak self] edit, window in
            _ = await self?.writeBack(edit, askingOver: window)
        }
        MergeWindowController.present(input, saving: saving)
    }

    /// What the window's saves do with `edit`'s copy: the first makes the archive's version kept in
    /// `theirs` the copy's base, and every one then carries the copy back through `writeBack`. A
    /// window closed with no save removes that version. `static` so it is assertable with no window.
    static func archiveMergeSaving(
        _ edit: EditedFile,
        theirs: ArchiveMemberBase,
        cache: ArchivePreviewCache,
        writeBack: @escaping @MainActor (EditedFile, NSWindow?) async -> Void
    ) -> MergeSaving {
        let pending = PendingMergeBase(theirs.base)
        return MergeSaving(
            undo: { .none },
            journal: { _ in },
            carry: { [weak cache] window in
                // Once, at the first save: the copy holds a merge with the archive's version from
                // then on, whatever happens to the rewrite.
                if let base = pending.take() {
                    cache?.adoptBase(
                        ofCopy: edit.temporaryURL,
                        ArchiveMemberBase(base: base, archive: theirs.archive)
                    )
                }
                await writeBack(edit, window)
            },
            closed: { [weak cache] in
                guard let base = pending.take() else { return }
                cache?.baseStore.discard(base)
            }
        )
    }

    // MARK: - Words

    static var archiveMergeTheirsDetail: String {
        String(
            localized: "In the archive now",
            comment: "Merge window, under Theirs: the member as its archive holds it now."
        )
    }

    static func archiveMergeResultDetail(_ archiveName: String) -> String {
        String(
            localized: "Saved into your editor’s copy and written back into “\(archiveName)”",
            comment: """
            Merge window, under Result: where a save puts the merged member; %@ is the archive's name.
            """
        )
    }

    /// Why Merge… cannot run once the base it was offered on has gone, such as after the copy was
    /// written back.
    static var archiveMergeNoBaseDetail: String {
        String(
            localized: """
            Dirnex no longer has the version your edit started from, so it can’t tell your changes \
            from the archive’s.
            """,
            comment: "Merge failure detail when the base version kept for an edited archive member is gone."
        )
    }
}
