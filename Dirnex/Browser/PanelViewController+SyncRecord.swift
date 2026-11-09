import AppKit
import DirnexCore

/// The pane's half of the sync's record (PLAN.md §M37 Slice 8): keeping what a sync left equal once
/// it has run, and the merge window on a file changed on both sides.
extension PanelViewController {
    /// Opens the merge window: the real one, or a test's that never goes on screen.
    typealias SyncMergeOpener = @MainActor (MergeInput, MergeSaving) -> MergeWindowController

    // MARK: - After a sync

    /// Carry out the box's choice once the sync's copies and deletes have finished, so the walk sees
    /// the folders as the sync left them.
    ///
    /// Answered with the work's task, for a test to wait on.
    @discardableResult
    func finishSyncRecord(
        _ choice: SyncRecordChoice?,
        after copies: Task<Void, Never>,
        _ deletes: Task<Void, Never>?
    ) -> Task<Void, Never>? {
        switch choice {
        case nil:
            return nil
        case let .forget(records):
            return Task {
                await BlockingWork.run(qos: .utility) { records.store.forget(records.pair) }
            }
        case let .keep(records):
            let backend = backend
            let mounts = VaultMounts.shared.mountPoints
            return Task { [weak self] in
                await copies.value
                await deletes?.value
                let outcome = await BlockingWork.run(qos: .utility) {
                    Result { () throws -> SyncKeepReport in
                        try records.store.remember(records.pair)
                        return try records.store.keep(
                            for: records.pair,
                            using: backend,
                            vaultMountPoints: mounts
                        )
                    }
                }
                self?.report(outcome)
            }
        }
    }

    /// Say what keeping came to on the status line. A failure here costs a later merge and nothing
    /// else, so it is not worth a dialog, and it still should not pass in silence.
    private func report(_ outcome: Result<SyncKeepReport, any Error>) {
        guard let sentence = Self.keepSentence(outcome) else { return }
        showTransientStatus(sentence)
    }

    static func keepSentence(_ outcome: Result<SyncKeepReport, any Error>) -> String? {
        guard case let .success(report) = outcome else {
            return String(
                localized: "Couldn’t keep versions for merging",
                comment: "Status line after a sync, when the versions kept for later merges could not be written."
            )
        }
        if report.overBudget > 0 {
            return String(
                localized: "\(report.overBudget) files didn’t fit in the space kept for merging",
                comment: """
                Status line after a sync; %lld is how many text files could not be kept for later \
                merges because the space set aside was full. Plural.
                """
            )
        }
        guard report.kept > 0 else { return nil }
        return String(
            localized: "Kept \(report.kept) versions for merging",
            comment: "Status line after a sync; %lld is how many text files were kept for later merges. Plural."
        )
    }

    // MARK: - Merge…

    /// Merge…: read the three versions off the main thread and open the merge window on them, or say
    /// why not. A merge window already open on the file comes forward instead.
    func mergeSyncRow(
        _ request: SyncMergeRequest,
        in sheet: SyncDirectoriesController?,
        opening open: @escaping SyncMergeOpener = { MergeWindowController.present($0, saving: $1) }
    ) {
        if let window = MergeWindowController.open.first(where: {
            $0.input.target.path == request.left.path.path
        }) {
            window.showWindow(nil)
            window.raiseAboveModalWindow()
            return
        }
        Task {
            let read = await BlockingWork.run { Self.readSyncMerge(request) }
            switch read {
            case let .success(input):
                _ = open(input, syncMergeSaving(request, in: sheet))
            case let .failure(failure):
                presentCompareFailure(
                    message: BrowserWindowController.mergeFailureTitle(request.left.name),
                    detail: CompareOpener.failureDetail(failure)
                )
            }
        }
    }

    /// The three versions read whole, the left file as Yours and the right as Theirs, with each file
    /// as it was just before it was read, which the window's save is checked against. Blocking; call
    /// it off the main thread.
    nonisolated static func readSyncMerge(_ request: SyncMergeRequest) -> Result<
        MergeInput,
        CompareReadFailure
    > {
        let right = ComparedFileSave.Target.reading(request.right.path.path)
        let read = BrowserWindowController.readMerge(
            base: request.base,
            yours: URL(fileURLWithPath: request.left.path.path),
            theirs: URL(fileURLWithPath: request.right.path.path)
        )
        return read.map { documents in
            let name = request.left.name
            let opening = documents.yours.text(ofFirstLines: SyntaxLanguage.contentsLineLimit)
            return MergeInput(
                name: name,
                base: MergeVersion(detail: syncMergeBaseDetail, document: documents.base),
                yours: MergeVersion(detail: request.left.path.path, document: documents.yours),
                theirs: MergeVersion(detail: request.right.path.path, document: documents.theirs),
                target: documents.target,
                resultDetail: syncMergeResultDetail,
                language: SyntaxLanguage.forFile(named: name, text: opening),
                secondTarget: right
            )
        }
    }

    /// The window's saves go into the undo store and this pane's journal as a compare window's do.
    /// Once both files hold the merge, it is what the pair last agreed on, and the row is answered
    /// again.
    func syncMergeSaving(
        _ request: SyncMergeRequest,
        in sheet: SyncDirectoriesController?
    ) -> MergeSaving {
        let mounts = VaultMounts.shared.mountPoints
        return MergeSaving(
            undo: compareSaving.undo,
            journal: compareSaving.journal,
            carry: { [weak sheet] _ in
                await BlockingWork.run(qos: .utility) {
                    _ = try? request.records.store.keep(
                        relativePath: request.relativePath,
                        left: URL(fileURLWithPath: request.left.path.path),
                        right: URL(fileURLWithPath: request.right.path.path),
                        for: request.records.pair,
                        vaultMountPoints: mounts
                    )
                }
                sheet?.compareAgain(rowShowing: request.left.path)
            }
        )
    }

    private nonisolated static var syncMergeBaseDetail: String {
        String(
            localized: "As of the last sync",
            comment: "Merge window, under Base: the version both synchronized folders last held."
        )
    }

    private nonisolated static var syncMergeResultDetail: String {
        String(
            localized: "Saved to both folders",
            comment: "Merge window, under Result: a save writes the merged file into both synchronized folders."
        )
    }
}
