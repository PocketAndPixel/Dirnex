import AppKit
import DirnexCore

/// Merge… in the write-back's prompts (PLAN.md §M34 Slice 4): a save of a server file whose copy on
/// the server changed under the edit merges the two edits instead of losing one.
///
/// The three versions are the base kept for the copy (`RemoteFileCache+Bases`), the copy the
/// editor saved, and the server's version as it is now, brought down through the download funnel
/// when Merge… is pressed. The merge window writes its result into the editor's copy, which is
/// then rebased onto the server's version it merged and carried up as any save of it is: the check
/// compares against that version, and the upload's precondition is read off it.
///
/// **Merge… is offered only when it can work**: one file, the server's copy changed, a base kept
/// for it, and the base and the copy both text. The server's version is not fetched to ask, since a
/// download is the gesture's to start (PLAN.md §6 ▸ M24's row), so it is checked when it arrives.
extension BrowserWindowController {
    // MARK: - Whether Merge… is offered

    /// The base a merge of `pending` starts from, or `nil` when Merge… cannot work
    /// (``mergeBase(_:yours:recorded:current:contentChanged:)``).
    func mergeBase(
        for pending: PendingWriteBack,
        recorded: RemoteFileRevision?,
        current: FileEntry?,
        contentChanged: Bool
    ) async -> URL? {
        await Self.mergeBase(
            remoteFileCache.base(ofCopy: pending.edit.temporaryURL),
            yours: pending.edit.temporaryURL,
            recorded: recorded,
            current: current,
            contentChanged: contentChanged
        )
    }

    /// `base`, when Merge… can work from it: the check found the server's copy changed since
    /// `recorded`, by its size and time or by its bytes (`contentChanged`), the server's copy is
    /// small enough for the window to read, and `base` and the copy at `yours` both read as text.
    /// `static` so the decision is assertable with no window.
    static func mergeBase(
        _ base: URL?,
        yours: URL,
        recorded: RemoteFileRevision?,
        current: FileEntry?,
        contentChanged: Bool = false
    ) async -> URL? {
        guard let base, let recorded, let current,
              contentChanged || recorded.isSuperseded(by: RemoteFileRevision(current)),
              mergeReads(byteSize: current.byteSize) else { return nil }
        let readable = await BlockingWork.run {
            (try? ComparedDocument.read(contentsOf: base)) != nil
                && (try? ComparedDocument.read(contentsOf: yours)) != nil
        }
        return readable ? base : nil
    }

    /// Whether the merge window reads a file of `byteSize` bytes: the compare window's limit, and
    /// not a file whose size the server never said.
    static func mergeReads(byteSize: Int64) -> Bool {
        byteSize >= 0 && byteSize <= ByteComparator.prescanByteLimit
    }

    // MARK: - Opening the merge

    /// Bring the server's version of `item` down and open the merge window on it, the base and the
    /// copy. Reports what stops it on `host`, and uploads nothing: the window's save does.
    func mergeWriteBack(_ item: CheckedWriteBack, over host: NSWindow?) async {
        let copy = item.edit.temporaryURL
        // One merge per copy. A window whose choices are not saved is the merge in hand; one whose
        // result is already in the copy is done, and the new merge starts from that result.
        let earlier = MergeWindowController.open.first { $0.input.target.path == copy.path }
        if let earlier, earlier.hasUnsavedChoices {
            earlier.showWindow(nil)
            return
        }
        guard let base = remoteFileCache.base(ofCopy: copy) else {
            return presentMergeFailure(item.edit.name, detail: Self.mergeNoBaseDetail, over: host)
        }
        let backend = focusedPanel.backend
        let destination = item.destination
        let stat = await BlockingWork.run { Result { try backend.stat(at: destination) } }
        let entry: FileEntry
        switch stat {
        case let .success(found):
            entry = found
        case let .failure(error):
            return presentMergeFailure(
                item.edit.name,
                detail: focusedPanel.describe(error),
                over: host
            )
        }
        guard Self.mergeReads(byteSize: entry.byteSize) else {
            return presentMergeFailure(
                item.edit.name,
                detail: CompareOpener.limitDetail(ByteComparator.prescanByteLimit),
                over: host
            )
        }
        guard let theirs = await fetchServerVersion(entry, of: item.edit.name, over: host) else { return }
        // Read from a duplicate kept now, which becomes the copy's base once the merge is saved: the
        // fetched copy is the path's for previews and F4 to hand out, and may be written later.
        let store = remoteFileCache.baseStore
        let revision = remoteFileCache.revision(ofCopy: theirs) ?? RemoteFileRevision(entry)
        guard let kept = await BlockingWork.run({ store.keep(theirs) }) else {
            return presentMergeFailure(
                item.edit.name,
                detail: VFSErrorText.sentence(for: CocoaError(.fileWriteUnknown)),
                over: host
            )
        }
        let read = await BlockingWork.run { Self.readMerge(base: base, yours: copy, theirs: kept) }
        switch read {
        case let .success(documents):
            earlier?.close()
            presentMerge(item, documents, theirs: kept, at: revision, over: host)
        case let .failure(failure):
            store.discard(kept)
            presentMergeFailure(
                item.edit.name,
                detail: CompareOpener.failureDetail(failure),
                over: host
            )
        }
    }

    /// The server's version of `entry`, through the download funnel, or `nil` when it could not be
    /// had. A copy this window holds of it is taken only if nothing has written it, so an edit is
    /// never read as the server's version.
    ///
    /// Unweighed, since the size is already within the window's limit, which is the edit row's
    /// threshold (`RemoteFetchPolicy`): F4 would have fetched it unasked. Stop and the progress
    /// sheet are the funnel's as for any fetch.
    private func fetchServerVersion(
        _ entry: FileEntry,
        of name: String,
        over host: NSWindow?
    ) async -> URL? {
        remoteFileCache.setAsideEditedCopy(of: entry)
        let context = RemoteFetchPrompt.Context(
            backend: focusedPanel.backend,
            cache: remoteFileCache,
            window: host ?? window
        )
        return await withCheckedContinuation { continuation in
            RemoteFetchPrompt.fetchConfirmed(
                entry,
                in: context,
                onCancel: { continuation.resume(returning: nil) },
                then: { continuation.resume(returning: $0) },
                onFailure: { [weak self] error in
                    self?.presentMergeFailure(
                        name,
                        detail: VFSErrorText.sentence(for: error),
                        over: host
                    )
                    continuation.resume(returning: nil)
                }
            )
        }
    }

    /// The three versions read whole, in the order base, yours, theirs, and yours' file as it was
    /// just before it was read, which the window's save is checked against. Blocking; call it off
    /// the main thread.
    nonisolated static func readMerge(
        base: URL,
        yours: URL,
        theirs: URL
    ) -> Result<MergeDocuments, CompareReadFailure> {
        let name = yours.lastPathComponent
        do {
            let baseDocument = try ComparedDocument.read(contentsOf: base)
            let target = ComparedFileSave.Target.reading(yours.path)
            let yoursDocument = try ComparedDocument.read(contentsOf: yours)
            let theirsDocument = try ComparedDocument.read(contentsOf: theirs)
            return .success(MergeDocuments(
                base: baseDocument,
                yours: yoursDocument,
                theirs: theirsDocument,
                target: target
            ))
        } catch {
            return .failure(CompareReadFailure(name: name, reason: error))
        }
    }

    /// Open the window on the three versions. Its save writes the result into the copy, makes the
    /// server's version kept at `theirs` the copy's base and `revision` what its next save is checked
    /// against, then carries the copy up as any save of it is.
    private func presentMerge(
        _ item: CheckedWriteBack,
        _ documents: MergeDocuments,
        theirs: URL,
        at revision: RemoteFileRevision,
        over host: NSWindow?
    ) {
        let name = item.edit.name
        let location = focusedPanel.compareDetail(for: item.destination)
        let opening = documents.yours.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
        let input = MergeInput(
            name: name,
            base: MergeVersion(detail: Self.mergeBaseDetail, document: documents.base),
            yours: MergeVersion(detail: Self.mergeYoursDetail, document: documents.yours),
            theirs: MergeVersion(detail: Self.mergeTheirsDetail, document: documents.theirs),
            target: documents.target,
            resultDetail: Self.mergeResultDetail(location),
            language: SyntaxLanguage.forFile(named: name, text: opening)
        )
        let pending = PendingMergeBase(theirs)
        let edit = item.edit
        let saving = MergeSaving(
            undo: { .none },
            journal: { _ in },
            carry: { [weak self] window in
                guard let self else { return }
                // Once, at the first save: the copy holds a merge with the server's version from
                // then on, whatever happens to the upload.
                if let base = pending.take() {
                    remoteFileCache.adoptBase(ofCopy: edit.temporaryURL, from: base)
                    remoteFileCache.rebase(copy: edit.temporaryURL, onto: revision)
                }
                _ = await writeBack(edit, askingOver: window)
            },
            closed: { [weak self] in
                guard let base = pending.take() else { return }
                self?.remoteFileCache.baseStore.discard(base)
            }
        )
        MergeWindowController.present(input, saving: saving)
    }

    private func presentMergeFailure(_ name: String, detail: String, over host: NSWindow?) {
        presentWriteBackFailure(
            message: String(
                localized: "Couldn’t merge “\(name)”",
                comment: "Alert title when the merge of a server file with its edit can't open; %@ is the name."
            ),
            detail: detail,
            over: host
        )
    }

    // MARK: - Words

    static var mergeButtonTitle: String {
        String(
            localized: "Merge…",
            comment: """
            Button in the upload prompt: merge the edited file with the server's changed version \
            instead of uploading over it.
            """
        )
    }

    /// A prompt's body with the sentence saying what Merge… does after it.
    static func mergeOfferBody(_ body: String) -> String {
        String(
            localized: """
            \(body) Merge… brings the server’s version down beside yours, so both edits can be kept.
            """,
            comment: """
            Upload prompt body when a merge is offered; %@ is the prompt's own body, which says the \
            server's copy changed.
            """
        )
    }

    static var mergeBaseDetail: String {
        String(
            localized: "Where your edit started",
            comment: "Merge window, under Base: the server's version the user's edit began from."
        )
    }

    /// Why Merge… cannot run once the base it was offered on has gone, such as after an upload
    /// whose outcome nobody knows.
    static var mergeNoBaseDetail: String {
        String(
            localized: """
            Dirnex no longer has the version your edit started from, so it can’t tell your changes \
            from the server’s.
            """,
            comment: "Merge failure detail when the base version kept for an edited server file is gone."
        )
    }

    static var mergeYoursDetail: String {
        String(
            localized: "Your edit",
            comment: "Merge window, under Yours: the user's edited copy of a server file."
        )
    }

    static var mergeTheirsDetail: String {
        String(
            localized: "On the server now",
            comment: "Merge window, under Theirs: the server's current version of the file."
        )
    }

    static func mergeResultDetail(_ location: String) -> String {
        String(
            localized: "Saved into your editor’s copy and uploaded to \(location)",
            comment: """
            Merge window, under Result: where a save puts the merged file; %@ is the server and path.
            """
        )
    }
}

/// The three versions a merge of a server file reads, and the file its save writes as it was read.
struct MergeDocuments: Sendable {
    let base: ComparedDocument
    let yours: ComparedDocument
    let theirs: ComparedDocument
    let target: ComparedFileSave.Target
}

/// The server's version kept for a merge, until the merge's first save makes it the copy's base or
/// the window closes without one.
@MainActor
final class PendingMergeBase {
    private var url: URL?

    init(_ url: URL) {
        self.url = url
    }

    /// The kept version, once: whoever takes it owns it.
    func take() -> URL? {
        defer { url = nil }
        return url
    }
}
