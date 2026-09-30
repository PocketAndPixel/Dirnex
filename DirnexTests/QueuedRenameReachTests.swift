import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app half of a rename the backend cannot perform in place (PLAN.md §M21): which failures are
/// handed to the queue, and what job they become.
///
/// The flow itself is not driven here, and the reason belongs with the suite: `queueDeferredRenames`
/// ends in a confirmation, which on a window-less pane falls back to `NSAlert.runModal()` — that
/// **wedges** the run rather than failing it, the same hazard `RenameReachTests` measured for
/// ⇧F2's modal window. So what is pinned is the two decisions either side of the sheet: the
/// classification (`RenameDeferral`), which is what routes an `EXDEV` away from the errno alert, and
/// the operation (`renameOperation(for:)`), which is where the destination could quietly be wrong.
/// The keystroke itself is verified live.
@MainActor
@Suite("Queued rename reach")
struct QueuedRenameReachTests {
    private static func pane(at path: VFSPath) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return pane
    }

    private static func folder(at path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    // MARK: - Which failures the queue can finish

    /// `EXDEV` is the backend asking for the long way round — an S3 prefix — and everything else is
    /// a real refusal that keeps its own alert. Both directions matter: reading a genuine failure as
    /// deferrable would offer to run a job that cannot work, and reading `EXDEV` as a failure is the
    /// shipped bug (the raw «error (code 18)»).
    @Test("only EXDEV is handed to the queue")
    func classification() {
        let path = VFSPath(backend: .local, path: "/dir/docs")
        #expect(RenameDeferral.isDeferred(VFSError.io(path: path, code: EXDEV)))
        #expect(!RenameDeferral.isDeferred(VFSError.io(path: path, code: EACCES)))
        #expect(!RenameDeferral.isDeferred(VFSError.io(path: path, code: 0)))
        #expect(!RenameDeferral.isDeferred(VFSError.notFound(path)))
        #expect(!RenameDeferral.isDeferred(VFSError.alreadyExists(path)))
        #expect(!RenameDeferral.isDeferred(VFSError.permissionDenied(path)))
        #expect(!RenameDeferral.isDeferred(CancellationError()))
    }

    // MARK: - The job it becomes

    @Test("the job renames the item in place, under the new name")
    func operationRenamesInPlace() {
        let pane = Self.pane(at: .local("/dir"))
        let entry = Self.folder(at: .local("/dir/docs"))

        let operation = pane.renameOperation(
            for: DeferredRename(source: entry, newName: "archive")
        )

        #expect(operation.kind == .move)
        #expect(operation.sources.map(\.path) == [entry.path])
        #expect(operation.destinationDirectory == .local("/dir"))
        #expect(operation.renamedTo == "archive")
        #expect(operation.landingName(for: entry) == "archive")
    }

    /// The trap this could fall into silently: in a tree the cursor's row lives in an expanded
    /// child, so a destination built from `panel.path` would rename the folder *and* move it to the
    /// root. Inline rename hit exactly that (docs/NOTES.md), which is why the job is built from the
    /// source's own parent.
    @Test("a row inside an expanded folder keeps its own directory")
    func operationUsesTheRowsOwnDirectory() {
        let pane = Self.pane(at: .local("/dir"))
        let entry = Self.folder(at: .local("/dir/sub/docs"))

        let operation = pane.renameOperation(
            for: DeferredRename(source: entry, newName: "archive")
        )

        #expect(operation.destinationDirectory == .local("/dir/sub"))
    }

    // MARK: - Nothing deferred

    /// ⇧F2 hands its `EXDEV` items here and reports the rest in `then`, so an empty list must run
    /// `then` and present nothing — a sheet raised over an empty batch would be a question about no
    /// items, and on a window-less pane it is a `runModal` that never returns.
    @Test("an empty batch presents nothing and still runs its continuation")
    func emptyBatchRunsItsContinuation() {
        let pane = Self.pane(at: .local("/dir"))
        var ran = false

        pane.queueDeferredRenames([], then: { ran = true })

        #expect(ran)
    }
}
