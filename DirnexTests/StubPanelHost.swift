import AppKit
import DirnexCore
import Foundation

@testable import Dirnex

/// A `PanelHost` that owns the window-scoped stores and does nothing else.
///
/// The pane reaches for its host whenever the thing it needs outlives a tab — the remote-file cache,
/// the archive caches, the edit watcher — so a pane built in a test with no host silently takes the
/// early return in every one of those paths. That is fine for a decision (`dropPlan` touches none of
/// them) and useless for a *flow*, which is why this exists: `PanelViewController+DragPromise` runs
/// a real fetch through `host.remoteFileCache`, and with no host it never starts one.
///
/// Every other requirement is a no-op rather than a recorder. What a test wants from a host here is
/// the stores; anything that wanted to observe a callback should record that callback, not inherit
/// twenty-five it does not read.
@MainActor
final class StubPanelHost: PanelHost {
    let remoteFileCache = RemoteFileCache()
    let archivePreviewCache = ArchivePreviewCache()
    let nestedArchiveRegistry = NestedArchiveRegistry()
    let archivePassphrases = ArchivePassphraseStore()
    let editedFiles = EditedFileRegistry()

    var quickViewMode: QuickViewMode = .off
    var isQuickViewEnabled: Bool { quickViewMode != .off }
    var nextUndoLabel: UndoActionLabel?
    var nextRedoLabel: UndoActionLabel?

    func panelDidBecomeActive(_ panel: PanelViewController) {}
    /// Every tab a pane closed, in order, with where it sat — the hand-over ⇧⌘T depends on.
    private(set) var closedTabs: [(tab: PanelTab, index: Int)] = []

    func panelDidCloseTab(_ tab: PanelTab, at index: Int, in panel: PanelViewController) {
        closedTabs.append((tab, index))
    }

    func panelRequestsFocusSwitch(_ panel: PanelViewController) {}
    /// The other pane, when a test needs one.
    ///
    /// `nil` by default and settable since M24 Slice 6, because ⌥F5 is the first gesture here whose
    /// *destination* is the counterpart: every question it asks — can this folder receive an
    /// archive, is it on this Mac — is about a pane this host has to be able to hand back.
    var counterpart: PanelViewController?

    func panelCounterpart(of panel: PanelViewController) -> PanelViewController? { counterpart }
    /// Every operation a gesture handed over, in order.
    ///
    /// Recorded rather than shrugged at since M24 Slice 4, because a checksum over rows that are
    /// not on this disk is a gesture whose whole answer is *what it queued*: the sources, and the
    /// map of which local file stands for each of them. Nothing runs — `ChecksumRunner` is tested
    /// in the core against a real backend — and what an app test can see is the hand-over.
    private(set) var enqueued: [FileOperation] = []

    func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    ) {
        enqueued.append(operation)
    }

    /// Every record a gesture journaled, in order.
    ///
    /// A recorder rather than a no-op for the reason `enqueued` is: journaling is a seam whose
    /// *absence* is invisible in every other direction. A remote Get Info that never handed a
    /// record over would save exactly as it does now and simply not be undoable, with no error, no
    /// log line and every other assertion green (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
    private(set) var recordedUndo: [UndoRecord] = []

    func recordUndoableAction(_ record: UndoRecord) { recordedUndo.append(record) }
    /// The marking changes a gesture journaled, in a real journal, so that withdrawing one is the
    /// core's own rule rather than a second copy of it. Every pane is `.left` here: a stub has no
    /// sides to tell apart.
    private(set) var selectionJournal = UndoJournal()

    func recordSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    ) {
        selectionJournal.record(
            .selection(selectionChange(on: pane, directory, previousMarks, label))
        )
    }

    func withdrawSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    ) -> Bool {
        selectionJournal.withdraw(
            .selection(selectionChange(on: pane, directory, previousMarks, label))
        )
    }

    private func selectionChange(
        on pane: PanelViewController,
        _ directory: VFSPath,
        _ previousMarks: Set<VFSPath>,
        _ label: UndoActionLabel
    ) -> SelectionChange {
        SelectionChange(
            pane: .left,
            directory: directory,
            priorSelection: previousMarks,
            newSelection: pane.panel.selection,
            label: label
        )
    }

    func undoLastOperation() {}
    func redoLastOperation() {}
    func captureWorkspace(named name: String) -> Workspace {
        let empty = WorkspacePane(tabs: [], activeTabIndex: 0)
        return Workspace(name: name, left: empty, right: empty)
    }

    func applyWorkspace(_ workspace: Workspace) {}
    func toggleQuickView(_ mode: QuickViewMode) {}

    /// How many times a pane asked to close Quick View. Recorded since the header grew a Close
    /// button (2026-10-18): in ⌃Q the surface belongs to the covered pane, and the button's whole
    /// answer is this call.
    private(set) var quickViewCloses = 0
    func closeQuickView() {
        quickViewCloses += 1
    }

    /// Every style a pane asked for, since the header's `1 Source · 2 Page` became buttons
    /// (2026-10-20): in ⌃Q the click lands in the covered pane, which has to pass it to the window.
    private(set) var quickViewStylePicks: [QuickViewRenderStyle] = []
    func setQuickViewRenderStyle(_ style: QuickViewRenderStyle) {
        quickViewStylePicks.append(style)
    }

    /// Every flip a pane asked for, and every scroll. Recorded since the ⇧-arrows learned to scroll
    /// the preview (2026-10-18): at full size the same arrow key flips or scrolls depending on ⇧, and
    /// which of the two calls a key made is the table's whole answer.
    private(set) var quickViewFlips: [Int] = []
    private(set) var quickViewScrolls: [QuickViewScroll] = []

    func flipQuickView(steps: Int) {
        quickViewFlips.append(steps)
    }

    /// Like the window's: consumed while a preview is up, and not otherwise.
    func scrollQuickView(_ move: QuickViewScroll) -> Bool {
        guard isQuickViewEnabled else { return false }
        quickViewScrolls.append(move)
        return true
    }

    func panelCursorDidChange(_ panel: PanelViewController) {}
    func panelDidNavigate(_ panel: PanelViewController) {}

    /// Every visit a pane reported, in order.
    ///
    /// A recorder rather than a no-op for the reason `recordedUndo` is. A pane that stopped
    /// reporting visits would pass every other test while the fuzzy jump stopped learning, and
    /// before these went through the host they went straight into the developer's own index.
    private(set) var frecencyVisits: [VFSPath] = []

    func recordFrecencyVisit(_ path: VFSPath) { frecencyVisits.append(path) }
    /// Every vault a pane asked the window to open, in order — what the right-click's Unlock Vault
    /// hands over is the whole of its effect from the pane's side.
    private(set) var vaultOpenRequests: [VaultLocation] = []

    func panelRequestsVaultOpen(
        _ vault: VaultLocation,
        showingIn pane: PanelViewController,
        inNewTab: Bool
    ) {
        vaultOpenRequests.append(vault)
    }

    /// The one requirement that records rather than shrugging, because it is the seam a whole
    /// milestone's gestures run through: a test hands back `materializeReport` and asserts on what
    /// was asked for. Nothing here transfers anything — `MaterializeRunner` is tested in the core
    /// against a real backend, and what an app test needs to see is which rows the *gesture*
    /// queued and what it then did with the answer.
    private(set) var materializedEntries: [[FileEntry]] = []
    /// What the queued job is said to have produced. `nil` withholds the answer entirely, which is
    /// the shape of a transfer still running.
    var materializeReport: OperationReport? = .empty

    /// Successive answers, for a gesture that fetches **more than once**. Verifying a manifest that
    /// is not on this disk is two-phase by construction — nothing can know what else to fetch until
    /// the manifest has been read — so a single answer would make the second phase hand back the
    /// first phase's copies and hide the bug the test exists for. Falls through to
    /// ``materializeReport`` once it is spent.
    var materializeReports: [OperationReport] = []

    func materializeRemoteFiles(
        _ entries: [FileEntry],
        then: @escaping @MainActor (OperationReport) -> Void
    ) {
        materializedEntries.append(entries)
        let next = materializeReports.isEmpty ? materializeReport : materializeReports.removeFirst()
        guard let materializeReport = next else { return }
        // The real host files the copies before answering, and the funnel reads them back out of
        // the cache — so a stub that skipped this would make every delivery look like a miss.
        remoteFileCache.adopt(materializeReport.materialized ?? [])
        then(materializeReport)
    }
}
