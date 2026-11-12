import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A transfer that waits to be let through, so a test can stand in the middle of one.
private final class GatedBackend: VFSBackend, @unchecked Sendable {
    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let lock = NSLock()
    private var isOpen = false
    private var shouldFail = false
    private var cancelled = false

    func open(failing: Bool = false) {
        lock.withLock {
            shouldFail = failing
            isOpen = true
        }
    }

    var wasCancelled: Bool { lock.withLock { cancelled } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }
    func stat(at path: VFSPath) throws -> FileEntry { Fixture.entry(path.lastComponent) }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        while !lock.withLock({ isOpen }) {
            if isCancelled() {
                lock.withLock { cancelled = true }
                throw CancellationError()
            }
            usleep(5000)
        }
        if lock.withLock({ shouldFail }) { throw VFSError.notFound(source) }
        try Data(CountingBackend.body.utf8).write(to: URL(fileURLWithPath: destination.path))
        progress(Int64(CountingBackend.body.utf8.count))
    }
}

/// Answers a read and counts them, for what must not be read.
private final class CountingProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var reads = 0

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        reads += 1
        item.setString("file:///tmp/asked-for.txt", forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}

/// The surfaces these tests move the pointer over.
private enum HandoffSurfaces {
    static let finder = RemoteDragHandoff.Surface.finder(processID: 10)
    static let teams = RemoteDragHandoff.Surface.otherApp(processID: 20)
    static let slack = RemoteDragHandoff.Surface.otherApp(processID: 30)
}

/// Everything a test watches about one controller. A class so the closures it hands over can
/// write to it, and so the pointer can be moved while a read is being held.
@MainActor
private final class Rig {
    let board: NSPasteboard
    let cache = RemoteFileCache()
    var surface: RemoteDragHandoff.Surface = HandoffSurfaces.teams
    var statuses: [String?] = []
    var landings = 0
    var failures = 0
    /// Called each time the hold looks at the pointer, so a test can move it during one.
    var onPointerAsked: (() -> Void)?
    var controller: RemoteDragHandoffController?

    init(_ name: String) {
        board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.handoff.\(name)"))
        board.clearContents()
    }

    func start(
        _ entries: [FileEntry],
        backend: any VFSBackend,
        holdLimit: Duration = .seconds(30)
    ) -> RemoteDragHandoffController {
        let controller = RemoteDragHandoffController(
            board: board,
            entries: entries,
            cache: cache,
            backend: backend,
            holdLimit: holdLimit,
            surfaceUnderPointer: { [self] in
                onPointerAsked?()
                return surface
            },
            showStatus: { [self] in statuses.append($0) },
            onLanded: { [self] in landings += 1 },
            onFailure: { [self] _ in failures += 1 }
        )
        self.controller = controller
        return controller
    }

    func read(row: Int = 0) -> String? {
        board.pasteboardItems?[row].string(forType: .fileURL)
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline, !condition() {
        try? await Task.sleep(for: .milliseconds(25))
    }
}

/// What a drag of remote rows does once the pointer is over another app. A drag session cannot be
/// synthesized, so the real board stands in for the session's, and the pointer is injected. The drags
/// themselves were checked against Finder and Teams (`RemoteDragHandoff`).
@MainActor
@Suite("Remote drag handoff controller")
struct RemoteDragHandoffControllerTests {
    // MARK: - AppKit reaches it

    /// By selector string, for the reason `DragPromiseTests` gives: AppKit asks through
    /// `respondsToSelector:`, and a method Swift compiled under another selector is never called.
    @Test("the table and the pane implement what a drag session calls, under the selectors it sends")
    func selectors() {
        #expect(
            FileTableView.instancesRespond(to: NSSelectorFromString("draggingSession:movedToPoint:"))
        )
        #expect(PanelViewController.instancesRespond(
            to: NSSelectorFromString("tableView:draggingSession:endedAtPoint:operation:")
        ))
    }

    // MARK: - The board's items

    @Test("a row's file URL is read only when somebody asks, and Dirnex's own drop does not ask")
    func ownDropReadsNoFileURL() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.handoff.items"))
        board.clearContents()
        let provider = CountingProvider()
        let entry = Fixture.entry("report.pdf")
        #expect(board.writeObjects(PanelPasteboard.handoffItems(for: [entry]) { _ in
            .answeredWhenRead(provider)
        }))
        #expect(board.pasteboardItems?.first?.types.contains(.fileURL) == true)

        // Reading the URL here would hold a drop inside Dirnex for a transfer it has no use for.
        guard case let .locations(rows) = PanelPasteboard.sources(in: board) else {
            Issue.record("A drop inside Dirnex has to read the payload")
            return
        }
        #expect(rows.map(\.path) == [entry.path])
        #expect(provider.reads == 0)

        #expect(board.pasteboardItems?.first?.string(forType: .fileURL) != nil)
        #expect(provider.reads == 1)
    }

    @Test("a row the closure says nothing about keeps the shape a plain item has")
    func otherRowsKeepTheirShape() {
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.handoff.mixed"))
        board.clearContents()
        let local = FileEntry(
            path: .local("/tmp/here.txt"), name: "here.txt", kind: .file, byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false, permissions: 0o644, inode: 1
        )
        board.writeObjects(PanelPasteboard.handoffItems(for: [local]) { _ in nil })
        #expect(
            board.pasteboardItems?.first?.string(forType: .fileURL) == local.path.localURL.absoluteString
        )
    }

    // MARK: - Leaving the promise

    @Test("Finder leaves the board and the server alone")
    func finderChangesNothing() {
        let rig = Rig("finder")
        let marker = NSPasteboard.PasteboardType("app.dirnex.tests.marker")
        rig.board.setString("the promise", forType: marker)
        rig.surface = HandoffSurfaces.finder
        let backend = CountingBackend(outcome: .succeed)
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)

        controller.pointerMoved()

        #expect(rig.board.string(forType: marker) == "the promise")
        #expect(backend.copyCount == 0)
        #expect(!controller.isTransferring)
    }

    @Test("another app gets a file URL and the payload, in place of what was there")
    func otherAppGetsAFileURL() async {
        let rig = Rig("rewrite")
        let marker = NSPasteboard.PasteboardType("app.dirnex.tests.marker")
        rig.board.setString("the promise", forType: marker)
        let controller = rig.start([Fixture.entry("report.pdf")], backend: CountingBackend())

        controller.pointerMoved()

        #expect(rig.board.string(forType: marker) == nil)
        #expect(rig.board.pasteboardItems?.first?.types.contains(.fileURL) == true)
        #expect(PanelPasteboard.payloads(in: rig.board).map(\.entry.name) == ["report.pdf"])
        await until { !controller.isTransferring }
    }

    // MARK: - Answering a read

    @Test("a read waits for the bytes and is answered with the real file")
    func readWaitsForTheFile() async throws {
        let rig = Rig("wait")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()
        // Let through only once the read is on the main thread waiting, so the transfer's finish
        // cannot have reached the main actor first. This is the deadlock the first version had.
        rig.onPointerAsked = { backend.open() }

        let answer = try #require(rig.read())

        let url = try #require(URL(string: answer))
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try String(contentsOf: url, encoding: .utf8) == CountingBackend.body)
        #expect(rig.cache.cachedURL(for: Fixture.entry("report.pdf")) != nil)
        await until { rig.landings == 1 }
        #expect(rig.landings == 1)
    }

    @Test("a row already fetched costs no transfer and no wait")
    func cachedRowIsImmediate() async throws {
        let rig = Rig("cached")
        let backend = CountingBackend(outcome: .succeed)
        let entry = Fixture.entry("report.pdf")
        _ = try await rig.cache.fetch(
            entry, using: backend, progress: { _ in }, isCancelled: { false }
        )
        let controller = rig.start([entry], backend: backend)

        controller.pointerMoved()

        #expect(!controller.isTransferring)
        #expect(rig.read() != nil)
        #expect(backend.copyCount == 1)
    }

    @Test("every row of a marked set gets its own file")
    func everyRowGetsItsFile() throws {
        let rig = Rig("rows")
        let controller = rig.start(
            [Fixture.entry("one.txt"), Fixture.entry("two.txt")], backend: CountingBackend()
        )
        controller.pointerMoved()

        let answers = try [0, 1].map { try #require(rig.read(row: $0)) }

        #expect(answers.compactMap { URL(string: $0)?.lastPathComponent } == ["one.txt", "two.txt"])
    }

    // MARK: - When the bytes are not there in time

    @Test(
        "a hold that runs out offers no file, for any row: a drop of some of them looks like success"
    )
    func holdRunsOutForEveryRow() {
        let rig = Rig("expired")
        let backend = GatedBackend()
        let controller = rig.start(
            [Fixture.entry("one.txt"), Fixture.entry("two.txt")],
            backend: backend,
            holdLimit: .milliseconds(50)
        )
        controller.pointerMoved()

        #expect(rig.read(row: 0) == nil)
        #expect(rig.read(row: 1) == nil)

        backend.open(failing: true)
    }

    @Test("the bytes landing after a refusal put the real file on the board, and say to come back")
    func landingAfterRefusal() async throws {
        let rig = Rig("late")
        let backend = GatedBackend()
        let controller = rig.start(
            [Fixture.entry("report.pdf")], backend: backend, holdLimit: .milliseconds(50)
        )
        controller.pointerMoved()
        #expect(rig.read() == nil)

        backend.open()
        await until { !controller.isTransferring }

        let answer = try #require(rig.read())
        let url = try #require(URL(string: answer))
        #expect(try String(contentsOf: url, encoding: .utf8) == CountingBackend.body)
        #expect(rig.statuses.last == RemoteDragStatus.ready)
    }

    @Test("the pointer moving on ends a hold, and the next app gets to wait for itself")
    func pointerLeavingEndsTheHold() async throws {
        let rig = Rig("left")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()

        // The first asks are the read's own, so the pointer moves once the hold is under way.
        var asked = 0
        rig.onPointerAsked = {
            asked += 1
            if asked > 3 { rig.surface = HandoffSurfaces.slack }
        }
        let started = Date()
        #expect(rig.read() == nil)
        // Far short of the 30 s this hold was allowed.
        #expect(Date().timeIntervalSince(started) < 20)
        rig.onPointerAsked = nil

        controller.pointerMoved()
        backend.open()
        let answer = try #require(rig.read())
        #expect(answer.hasSuffix("report.pdf"))
    }
}

/// How a drag of remote rows ends, which is the part that decides what happens to the transfer.
@MainActor
@Suite("Remote drag handoff, the drag ending")
struct RemoteDragHandoffEndingTests {
    @Test("a transfer that may not finish is stopped, and leaves nothing behind")
    func endStopsTheTransfer() async {
        let rig = Rig("stop")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()

        controller.dragEnded(mayFinish: false)
        await until { backend.wasCancelled }

        #expect(backend.wasCancelled)
        #expect(rig.cache.cachedURL(for: Fixture.entry("report.pdf")) == nil)
        #expect(rig.failures == 0)
    }

    @Test("a transfer that may finish does, so a second try costs nothing")
    func endLeavesTheTransfer() async {
        let rig = Rig("finish")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()

        controller.dragEnded(mayFinish: true)
        backend.open()
        await until { !controller.isTransferring }

        #expect(rig.cache.cachedURL(for: Fixture.entry("report.pdf")) != nil)
    }

    @Test("a failure during the drag is reported when it ends, once")
    func failureDuringTheDrag() async {
        let rig = Rig("failed")
        let controller = rig.start(
            [Fixture.entry("report.pdf")], backend: CountingBackend(outcome: .fail)
        )
        controller.pointerMoved()
        await until { !controller.isTransferring }

        #expect(rig.read() == nil)
        #expect(rig.failures == 0)
        #expect(rig.statuses.last == RemoteDragStatus.failed)

        controller.dragEnded(mayFinish: true)
        controller.dragEnded(mayFinish: true)
        #expect(rig.failures == 1)
    }

    /// Nobody is holding a drag any more, and the next try will say so if it matters.
    @Test("a failure after the drag ended is not reported")
    func failureAfterTheDrag() async {
        let rig = Rig("silent")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()

        controller.dragEnded(mayFinish: true)
        backend.open(failing: true)
        await until { !controller.isTransferring }

        #expect(rig.failures == 0)
    }

    @Test("a drag over stops holding reads at once")
    func noHoldAfterTheDrag() async {
        let rig = Rig("over")
        let backend = GatedBackend()
        let controller = rig.start([Fixture.entry("report.pdf")], backend: backend)
        controller.pointerMoved()
        controller.dragEnded(mayFinish: true)

        let started = Date()
        #expect(rig.read() == nil)
        #expect(Date().timeIntervalSince(started) < 20)

        backend.open()
        await until { !controller.isTransferring }
    }

    // MARK: - The pane's end-of-drag decision

    /// The pane's own weighing of what is left, against the size table's ``RemoteFetchPurpose/dragOut``.
    @Test("the pane stops what is too large to finish unasked, and leaves the rest")
    func paneWeighsWhatIsLeft() async {
        let backend = GatedBackend()
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: VFSPath(backend: backend.id, path: "/"),
            restorationKey: nil
        )
        let host = StubPanelHost()
        pane.host = host

        let large = RemoteFetchPolicy.threshold(
            for: .dragOut, previewLimit: AppPreferences.shared.quickViewFetchLimit
        ) + 1
        let controller = RemoteDragHandoffController(
            board: NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.handoff.pane")),
            entries: [Fixture.entry("large.bin", byteSize: large)],
            cache: host.remoteFileCache,
            backend: backend,
            surfaceUnderPointer: { HandoffSurfaces.teams },
            showStatus: { _ in },
            onLanded: {},
            onFailure: { _ in }
        )
        pane.dragHandoff = controller
        controller.pointerMoved()

        pane.endDragHandoff()
        await until { backend.wasCancelled }

        #expect(backend.wasCancelled)
    }

    // MARK: - The wording

    @Test("the status says how far, and never more than all of it")
    func statusWording() {
        #expect(RemoteDragStatus.downloading(moved: 50, of: 200).contains("25"))
        #expect(RemoteDragStatus.downloading(moved: 500, of: 200).contains("100"))
        #expect(!RemoteDragStatus.downloading(moved: 50, of: nil).contains("%"))
        #expect(!RemoteDragStatus.downloading(moved: 50, of: 0).contains("%"))
        #expect(!RemoteDragStatus.downloading(moved: 0, of: 200).contains("%"))
    }
}
