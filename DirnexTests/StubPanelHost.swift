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
    func panelRequestsFocusSwitch(_ panel: PanelViewController) {}
    func panelCounterpart(of panel: PanelViewController) -> PanelViewController? { nil }
    func enqueue(
        _ operation: FileOperation,
        conflictPolicy: ConflictPolicy,
        resolveConflict: (@Sendable (ConflictContext) -> ConflictResolution)?,
        onError: (@Sendable (OperationErrorContext) -> ErrorResolution)?
    ) {}
    func recordUndoableAction(_ record: UndoRecord) {}
    func recordSelectionChange(
        on pane: PanelViewController,
        directory: VFSPath,
        previousMarks: Set<VFSPath>,
        label: UndoActionLabel
    ) {}
    func undoLastOperation() {}
    func redoLastOperation() {}
    func captureWorkspace(named name: String) -> Workspace {
        let empty = WorkspacePane(tabs: [], activeTabIndex: 0)
        return Workspace(name: name, left: empty, right: empty)
    }

    func applyWorkspace(_ workspace: Workspace) {}
    func toggleQuickView(_ mode: QuickViewMode) {}
    func closeQuickView() {}
    func flipQuickView(steps: Int) {}
    func panelCursorDidChange(_ panel: PanelViewController) {}
    func panelDidNavigate(_ panel: PanelViewController) {}
    func panelRequestsVaultOpen(_ vault: VaultLocation, showingIn pane: PanelViewController) {}

    /// The one requirement that records rather than shrugging, because it is the seam a whole
    /// milestone's gestures run through: a test hands back `materializeReport` and asserts on what
    /// was asked for. Nothing here transfers anything — `MaterializeRunner` is tested in the core
    /// against a real backend, and what an app test needs to see is which rows the *gesture*
    /// queued and what it then did with the answer.
    private(set) var materializedEntries: [[FileEntry]] = []
    /// What the queued job is said to have produced. `nil` withholds the answer entirely, which is
    /// the shape of a transfer still running.
    var materializeReport: OperationReport? = .empty

    func materializeRemoteFiles(
        _ entries: [FileEntry],
        then: @escaping @MainActor (OperationReport) -> Void
    ) {
        materializedEntries.append(entries)
        guard let materializeReport else { return }
        // The real host files the copies before answering, and the funnel reads them back out of
        // the cache — so a stub that skipped this would make every delivery look like a miss.
        remoteFileCache.adopt(materializeReport.materialized ?? [])
        then(materializeReport)
    }
}
