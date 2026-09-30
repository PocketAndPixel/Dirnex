import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where a drag may be dropped, and what it does when it lands (PLAN.md §M23 Slice 3).
///
/// Driven through `dropPlan` itself, which touches no table and no drag session — so the decision
/// is fully reachable without presenting one. That matters beyond convenience: this project has
/// already paid for a suite that tore down windows holding settling sheets, and the crash landed on
/// *later* tests naming features that worked (docs/NOTES.md ▸ Testing).
///
/// Two of these pin bugs that were unreachable until this slice made remote panes drop targets, and
/// the more expensive one is the **default kind**: a `nil` volume identifier read as "one volume",
/// so an unmodified drag onto a server would have been a move, deleting the local original.
@MainActor
@Suite("Drop reach")
struct DropReachTests {
    private static let bucket = S3Location(
        host: "127.0.0.1",
        port: 9599,
        bucket: "probe",
        region: "us-east-1",
        accessKeyID: "AKIAPROBEKEYEXAMPLE",
        addressing: .path,
        usesTLS: false
    )
    private static let bucketID = VFSBackendID.s3(bucket)
    private static let accountID = VFSBackendID.s3Account(bucket.account)

    /// A backend whose volumes are indistinguishable — exactly what `CompositeBackend` reports for
    /// any non-local path, and the shape that made the default-move bug reachable.
    private struct StubBackend: VFSBackend {
        let id: VFSBackendID
        let capabilities: VFSCapabilities

        func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
        func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }
        func volumeIdentifier(for path: VFSPath) -> String? {
            path.backend == .local ? "boot" : nil
        }
    }

    private func pane(
        at path: VFSPath,
        capabilities: VFSCapabilities = [.read, .write],
        rows: [FileEntry] = []
    ) -> PanelViewController {
        let pane = PanelViewController(
            backend: StubBackend(id: path.backend, capabilities: capabilities),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        if !rows.isEmpty {
            pane.panel.setModel(
                DirectoryModel(listing: DirectoryListing(path: path, entries: rows))
            )
        }
        return pane
    }

    private func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 32,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 3
        )
    }

    /// A drag carrying `entries`, offering whatever a pane-to-pane drag offers by default.
    private func drag(
        _ entries: [FileEntry],
        mask: NSDragOperation = [.copy, .move],
        board name: String = "drop"
    ) -> StubDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.\(name)"))
        board.clearContents()
        _ = PanelPasteboard.write(entries, to: board)
        return StubDraggingInfo(board: board, mask: mask)
    }

    // MARK: - Where a drop may land

    @Test("a bucket accepts a drop from this Mac — the destination that used to be refused")
    func bucketAcceptsADrop() throws {
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/prefix"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/report.pdf"))], board: "bucket"),
            row: -1,
            dropOperation: .above
        ))
        #expect(plan.destination == VFSPath(backend: Self.bucketID, path: "/prefix"))
    }

    @Test("an S3 account pane refuses one — its rows are buckets, not folders")
    func accountPaneRefusesADrop() {
        let pane = pane(at: VFSPath(backend: Self.accountID, path: "/"))
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/report.pdf"))], board: "account"),
            row: -1, dropOperation: .above
        ) == nil)
    }

    @Test("a read-only pane refuses one")
    func readOnlyPaneRefusesADrop() {
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/"), capabilities: .read)
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/a.txt"))], board: "readonly"), row: -1, dropOperation: .above
        ) == nil)
    }

    @Test("a results listing refuses one — it has no directory of its own")
    func resultsListingRefusesADrop() {
        let pane = pane(at: VFSPath(backend: .search, path: "/results"))
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/a.txt"))], board: "results"), row: -1, dropOperation: .above
        ) == nil)
    }

    @Test("a row on a server can be dropped into a local folder")
    func remoteRowDropsIntoALocalFolder() throws {
        let pane = pane(at: .local("/tmp/dest"))
        let object = entry(VFSPath(backend: Self.bucketID, path: "/report.pdf"))
        let plan = try #require(pane.dropPlan(
            drag([object], board: "remote-in"), row: -1, dropOperation: .above
        ))
        #expect(plan.destination == .local("/tmp/dest"))
        guard case let .locations(entries) = plan.sources else {
            Issue.record("a Dirnex drag must arrive as locations, not as URLs")
            return
        }
        #expect(entries.map(\.path) == [object.path])
    }

    // MARK: - Copy or move

    @Test("an unmodified drag onto a server COPIES — the case that would have deleted the original")
    func dropOntoAServerCopies() throws {
        // Before this slice `volumeIdentifier` answered `nil` for the bucket, `sameVolume` read two
        // unknowns as equal, and the default was `.move`: the local file would have been removed.
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/prefix"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/report.pdf"))], board: "kind-remote"),
            row: -1, dropOperation: .above
        ))
        #expect(plan.kind == .copy)
        #expect(plan.operation == .copy)
    }

    @Test("an unmodified drag within one local volume still moves, as it always did")
    func dropWithinOneVolumeMoves() throws {
        let pane = pane(at: .local("/tmp/dest"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/src/a.txt"))], board: "kind-local"),
            row: -1, dropOperation: .above
        ))
        #expect(plan.kind == .move)
    }

    @Test("a drag from another app offers copy only, and copies")
    func externalDragCopies() throws {
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/prefix"))
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.external"))
        board.clearContents()
        #expect(board.writeObjects([URL(fileURLWithPath: "/tmp/finder.txt") as NSURL]))

        let plan = try #require(pane.dropPlan(
            StubDraggingInfo(board: board, mask: .copy), row: -1, dropOperation: .above
        ))
        #expect(plan.kind == .copy)
        // A foreign board still owes a stat, which is what keeps the two carriers apart.
        guard case .fileURLs = plan.sources else {
            Issue.record("a Finder drag must arrive as URLs")
            return
        }
    }

    // MARK: - Refusals that must survive

    @Test("dropping a folder into its own subtree is refused")
    func refusesRecursionIntoItsOwnSubtree() {
        let pane = pane(at: .local("/tmp/src/inner"))
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/src"), kind: .directory)], board: "recurse"),
            row: -1, dropOperation: .above
        ) == nil)
    }

    @Test("the same path on another backend is not a recursion — what the string test refused")
    func allowsTheSamePathOnAnotherBackend() throws {
        // `destination.path.hasPrefix(source.path + "/")` answered true here, so this ordinary
        // cross-backend drop was silently rejected with no message.
        let pane = pane(at: VFSPath(backend: Self.bucketID, path: "/tmp/inbox"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp"), kind: .directory)], board: "cross"),
            row: -1, dropOperation: .above
        ))
        #expect(plan.destination == VFSPath(backend: Self.bucketID, path: "/tmp/inbox"))
    }

    @Test("dropping items onto the folder they already live in is a no-op")
    func refusesADropOntoTheirOwnFolder() {
        let pane = pane(at: .local("/tmp/dest"))
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/dest/a.txt"))], board: "noop"), row: -1, dropOperation: .above
        ) == nil)
    }

    @Test("the table is registered for both carriers, or no drag ever reaches these rules")
    func tableAcceptsBothCarriers() {
        // The one wiring fact a headless test can reach: a real drag session cannot be synthesized
        // (docs/NOTES.md — synthetic events are not gestures), so what is checkable is that AppKit
        // has been told to accept our type at all. Without it every rule above is unreachable and
        // the pane simply refuses drags, silently.
        let pane = pane(at: .local("/tmp"))
        pane.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(pane)
        let registered = pane.tableView.registeredDraggedTypes
        #expect(registered.contains(PanelPasteboard.locationsType))
        #expect(registered.contains(.fileURL), "a Finder drag must still be accepted")
    }

    @Test("an empty board is not a drop")
    func refusesAnEmptyBoard() {
        let pane = pane(at: .local("/tmp"))
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.emptydrop"))
        board.clearContents()
        #expect(pane.dropPlan(
            StubDraggingInfo(board: board, mask: [.copy, .move]), row: -1, dropOperation: .above
        ) == nil)
    }
}

/// The two things `dropPlan` asks a drag about. Every other `NSDraggingInfo` requirement is
/// answered with a neutral value it never reads.
final class StubDraggingInfo: NSObject, NSDraggingInfo {
    private let board: NSPasteboard
    private let mask: NSDragOperation

    init(board: NSPasteboard, mask: NSDragOperation) {
        self.board = board
        self.mask = mask
    }

    var draggingPasteboard: NSPasteboard { board }
    var draggingSourceOperationMask: NSDragOperation { mask }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }

    var numberOfValidItemsForDrop: Int {
        get { 0 }
        set { _ = newValue }
    }

    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }

    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
