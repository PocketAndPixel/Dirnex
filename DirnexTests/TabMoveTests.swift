import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Moving tabs with the mouse: dropping a chip on its own strip or on the other pane's, and a chip's
/// menu. The keyboard's moves are `TabMoveKeyTests`.
///
/// The drops are driven through the strips' own `NSDraggingDestination` methods with a hand-made
/// `NSDraggingInfo`, because a drag *session* cannot be synthesized; what that leaves to a person is
/// that a real drag reaches those methods.
@MainActor
@Suite("Moving tabs by dropping a chip and from its menu", .serialized)
struct TabMoveTests {
    private typealias Panes = TabMovePanes

    // MARK: - Dropping a chip

    private func chipFrame(_ index: Int, in bar: TabBarView) -> NSRect {
        bar.chips[index].convert(bar.chips[index].bounds, to: bar)
    }

    /// A drag of chip `index` of `source`, with the pointer over `bar` at `x` in its coordinates.
    private func drag(_ index: Int, of source: TabBarView, over bar: TabBarView, atX x: CGFloat) -> TabDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.tab-drag"))
        board.clearContents()
        board.setString(String(index), forType: TabBarView.tabDragType)
        let location = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
        return TabDraggingInfo(board: board, source: source, location: location)
    }

    /// The bug the first strip shipped: released in the gap before gamma, alpha landed after it.
    @Test("a chip dropped along its own strip lands in the gap the marker showed")
    func dropAlongTheStrip() async throws {
        let panes = try await Panes.make()
        let bar = panes.left.pane.tabBar
        // Left of gamma's middle and right of beta's: the gap between the two.
        let info = drag(0, of: bar, over: bar, atX: chipFrame(2, in: bar).minX + 1)

        #expect(bar.dropOperation(for: info) == .move)
        #expect(!bar.insertionMarker.isHidden)
        #expect(bar.performDragOperation(info))

        #expect(panes.leftPaths == [Panes.beta, Panes.alpha, Panes.gamma])
        #expect(panes.left.pane.panel.path == Panes.gamma)
        #expect(bar.insertionMarker.isHidden)
    }

    @Test("a drop that would leave the chip where it is is refused, with no marker")
    func noOpDropIsRefused() async throws {
        let panes = try await Panes.make()
        let bar = panes.left.pane.tabBar
        // Beta nudged right, still left of gamma's middle.
        let info = drag(1, of: bar, over: bar, atX: chipFrame(1, in: bar).maxX - 1)

        #expect(bar.dropOperation(for: info).isEmpty)
        #expect(bar.insertionMarker.isHidden)
        #expect(!bar.performDragOperation(info))
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
    }

    @Test("a chip dropped on the other pane's strip moves there, even onto a single tab")
    func dropOnTheOtherStrip() async throws {
        let panes = try await Panes.make()
        let (source, target) = (panes.left.pane.tabBar, panes.right.pane.tabBar)
        // Past the middle of the only chip: the gap after it.
        let info = drag(0, of: source, over: target, atX: chipFrame(0, in: target).maxX + 2)
        #expect(target.dropOperation(for: info) == .move)
        #expect(target.performDragOperation(info))

        #expect(panes.rightPaths == [Panes.other, Panes.alpha])
        #expect(panes.right.pane.panel.path == Panes.alpha)
        #expect(panes.leftPaths == [Panes.beta, Panes.gamma])
        #expect(panes.left.pane.panel.path == Panes.gamma)
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)
    }

    /// The row is the title bar's whether or not a strip fills it, so a pane with one tab costs the
    /// file list nothing and the two lists start level. The strip's middle, 16 from the top, is where
    /// the traffic lights' is in the window's 32 pt title bar (measured 2026-11-01).
    @Test("a pane shows its strip for one tab as for three, and the path bars start level")
    func stripsLineUp() async throws {
        let panes = try await Panes.make()
        for pane in [panes.left.pane, panes.right.pane] {
            #expect(!pane.tabBar.isHidden)
            let top = pane.view.bounds.height
            let strip = pane.tabBar.convert(pane.tabBar.bounds, to: pane.view)
            let path = pane.pathBar.convert(pane.pathBar.bounds, to: pane.view)
            #expect(abs(top - strip.midY - 16) < 0.5, "\(strip) in \(top)")
            #expect(abs(top - path.maxY - 32) < 0.5, "\(path) in \(top)")
        }
    }

    @Test("anything that is not a tab chip is not accepted by a strip")
    func otherDragsAreRefused() async throws {
        let panes = try await Panes.make()
        let bar = panes.left.pane.tabBar
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.tab-drag"))
        board.clearContents()
        board.setString("0", forType: TabBarView.tabDragType)
        // The right type, but from no strip: not a chip of this window.
        let stray = TabDraggingInfo(board: board, source: nil, location: .zero)
        #expect(bar.dropOperation(for: stray).isEmpty)
        #expect(!bar.performDragOperation(stray))
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
    }

    /// The trap docs/NOTES.md ▸ Delegates in Swift 6 records: an optional `@objc` requirement on a
    /// main-actor class can conform and never be emitted, and then AppKit never calls it. Asserted
    /// by selector string, since `#selector(Protocol.method)` keeps naming it whether or not it is.
    @Test("the strip's drag-session callbacks are real Objective-C methods")
    func draggingSourceSelectorsAreEmitted() {
        for name in [
            "draggingSession:sourceOperationMaskForDraggingContext:",
            "draggingSession:endedAtPoint:operation:"
        ] {
            #expect(TabBarView.instancesRespond(to: Selector(name)), "\(name)")
        }
    }

    @Test("a chip's drag image is opaque, even for a tab with no fill of its own")
    func dragImageIsOpaque() async throws {
        let panes = try await Panes.make()
        let chip = panes.left.pane.tabBar.chips[0]
        #expect(chip.colors.background.alphaComponent == 0)

        let image = chip.dragImage()
        #expect(image.size == chip.bounds.size)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let middle = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(middle.alphaComponent > 0.9)
    }

    // MARK: - A chip's menu

    @Test("a chip's menu moves that chip's tab, not the one showing, and closes it too")
    func chipMenu() async throws {
        let panes = try await Panes.make()
        let bar = panes.left.pane.tabBar
        let menu = bar.chipMenu(for: bar.chips[0])
        let move = try #require(menu.items.first)
        let close = try #require(menu.items.last)
        #expect(move.title == LocalizedCatalog.command(for: "window.moveTabToOtherPanel")?.title)
        #expect(close.title == LocalizedCatalog.command(for: "file.closeTab")?.title)
        // The command's key acts on the tab showing, so the chip's item must not advertise it.
        #expect(move.keyEquivalent.isEmpty)

        #expect(NSApp.sendAction(try #require(move.action), to: move.target, from: move))
        #expect(panes.rightPaths == [Panes.other, Panes.alpha])
        #expect(panes.leftPaths == [Panes.beta, Panes.gamma])
        #expect(panes.left.pane.panel.path == Panes.gamma)

        let closeBeta = try #require(bar.chipMenu(for: bar.chips[0]).items.last)
        #expect(
            NSApp.sendAction(try #require(closeBeta.action), to: closeBeta.target, from: closeBeta)
        )
        #expect(panes.leftPaths == [Panes.gamma])
    }
}

/// A drag as a strip sees it: the pasteboard, the bar it came from, and where the pointer is. Every
/// other `NSDraggingInfo` requirement is answered with a neutral value the strip never reads.
final class TabDraggingInfo: NSObject, NSDraggingInfo {
    private let board: NSPasteboard
    private let source: TabBarView?
    private let location: NSPoint

    init(board: NSPasteboard, source: TabBarView?, location: NSPoint) {
        self.board = board
        self.source = source
        self.location = location
    }

    var draggingPasteboard: NSPasteboard { board }
    var draggingSource: Any? { source }
    var draggingLocation: NSPoint { location }
    var draggingSourceOperationMask: NSDragOperation { .move }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
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
