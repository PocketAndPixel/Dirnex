import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Moving tabs: ⌥⌘[ and ⌥⌘] along a strip, ⇧⌘M to the other pane, a chip's menu, and dropping a chip
/// on its own strip or on the other pane's.
///
/// Two panes in windows of their own, on a stub backend. The drops are driven through the strips'
/// own `NSDraggingDestination` methods with a hand-made `NSDraggingInfo`, because a drag *session*
/// cannot be synthesized; what that leaves to a person is that a real drag reaches those methods.
@MainActor
@Suite("Moving tabs along a strip and to the other pane", .serialized)
struct TabMoveTests {
    private static let alpha = VFSPath.local("/tmp/dirnex-tab-moves/alpha")
    private static let beta = VFSPath.local("/tmp/dirnex-tab-moves/beta")
    private static let gamma = VFSPath.local("/tmp/dirnex-tab-moves/gamma")
    private static let other = VFSPath.local("/tmp/dirnex-tab-moves/other")
    private static let marked = Handoff.local("/tmp/dirnex-tab-moves/gamma/marked.txt")
    private static let plain = Handoff.local("/tmp/dirnex-tab-moves/gamma/plain.txt")
    private static let leftKey = "tab-moves-left"
    private static let rightKey = "tab-moves-right"

    @MainActor
    private struct Panes {
        let left: WindowedPane
        let right: WindowedPane

        var leftPaths: [VFSPath] { left.pane.tabs.map(\.panel.path) }
        var rightPaths: [VFSPath] { right.pane.tabs.map(\.panel.path) }
    }

    /// The left pane on tabs alpha, beta and gamma, showing gamma; the right pane on its one tab. Both save their
    /// tabs into the scratch domain, each under a key of its own.
    private func makePanes() async throws -> Panes {
        let backend = Handoff.StubBackend(listings: [Self.gamma: [Self.marked, Self.plain]])
        let left = windowedPane(at: Self.alpha, backend: backend)
        let right = windowedPane(at: Self.other, backend: backend)
        left.host.counterpart = right.pane
        right.host.counterpart = left.pane
        for (pane, key) in [(left.pane, Self.leftKey), (right.pane, Self.rightKey)] {
            pane.tabStateDefaults = TabStateScratch.defaults
            pane.restorationKey = key
        }
        try await settleUntil { left.pane.tabs[0].hasLoaded && right.pane.tabs[0].hasLoaded }
        // One at a time: opening a tab supersedes the listing still in flight for the one before.
        left.pane.openInNewTab(Self.beta)
        try await settleUntil { left.pane.tabs[1].hasLoaded }
        left.pane.openInNewTab(Self.gamma)
        try await settleUntil { left.pane.tabs[2].hasLoaded }
        left.window.layoutIfNeeded()
        right.window.layoutIfNeeded()
        return Panes(left: left, right: right)
    }

    private func saved(_ key: String) throws -> PersistedPane {
        try #require(TabPersistence.load(paneKey: key, from: TabStateScratch.defaults))
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    // MARK: - The keyboard

    @Test("⌥⌘[ and ⌥⌘] step the showing tab along the strip, stop at its ends, and are saved")
    func stepAlongTheStrip() async throws {
        let panes = try await makePanes()
        let pane = panes.left.pane
        let left = #selector(PanelViewController.moveTabLeft(_:))
        let right = #selector(PanelViewController.moveTabRight(_:))
        pane.selectTab(at: 1)

        pane.moveTabLeft(nil)
        #expect(panes.leftPaths == [Self.beta, Self.alpha, Self.gamma])
        #expect(pane.panel.path == Self.beta)
        #expect(!pane.validateMenuItem(menuItem(left)))
        pane.moveTabLeft(nil)
        #expect(panes.leftPaths == [Self.beta, Self.alpha, Self.gamma])

        pane.moveTabRight(nil)
        pane.moveTabRight(nil)
        #expect(panes.leftPaths == [Self.alpha, Self.gamma, Self.beta])
        #expect(pane.panel.path == Self.beta)
        #expect(!pane.validateMenuItem(menuItem(right)))
        #expect(pane.validateMenuItem(menuItem(left)))

        // Saved as it changes, not only on the way down.
        let persisted = try saved(Self.leftKey)
        #expect(persisted.tabs.map(\.path).map(VFSPath.local) == [Self.alpha, Self.gamma, Self.beta])
        #expect(persisted.activeIndex == 2)
    }

    @Test("⇧⌘M moves the showing tab beside the other pane's, shows it there and takes the focus")
    func sendToTheOtherPane() async throws {
        let panes = try await makePanes()
        let moving = panes.left.pane.tabs[2]
        moving.panel.setSelection([Self.marked.path])

        panes.left.pane.moveTabToOtherPanel(nil)

        #expect(panes.leftPaths == [Self.alpha, Self.beta])
        #expect(panes.left.pane.panel.path == Self.beta)
        #expect(panes.rightPaths == [Self.other, Self.gamma])
        #expect(panes.right.pane.activeTabIndex == 1)
        // The same tab, so what is its own comes along: here, its marks.
        #expect(panes.right.pane.tabs[1] === moving)
        #expect(panes.right.pane.panel.selection == [Self.marked.path])
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)

        #expect(
            try saved(Self.leftKey).tabs.map(\.path).map(VFSPath.local) == [Self.alpha, Self.beta]
        )
        let right = try saved(Self.rightKey)
        #expect(right.tabs.map(\.path).map(VFSPath.local) == [Self.other, Self.gamma])
        #expect(right.activeIndex == 1)
    }

    @Test("a pane's last tab stays, and Move Tab to Other Panel is unavailable there")
    func lastTabStays() async throws {
        let panes = try await makePanes()
        let action = #selector(PanelViewController.moveTabToOtherPanel(_:))
        #expect(!panes.right.pane.validateMenuItem(menuItem(action)))
        #expect(panes.left.pane.validateMenuItem(menuItem(action)))

        panes.right.pane.moveTabToOtherPanel(nil)

        #expect(panes.rightPaths == [Self.other])
        #expect(panes.leftPaths == [Self.alpha, Self.beta, Self.gamma])
    }

    @Test("the Window menu carries the three moves on ⌥⌘[, ⌥⌘] and ⇧⌘M")
    func windowMenuItems() throws {
        let menu = MainMenuBuilder.build(
            bindings: KeyBindingStore(defaults: ScratchDefaults.fresh())
        )
        let items = Self.flatten(menu)
        let expected: [Selector: KeyEquivalent] = [
            #selector(PanelViewController.moveTabLeft(_:)): KeyEquivalent(
                key: "[",
                mask: [.command, .option]
            ),
            #selector(PanelViewController.moveTabRight(_:)): KeyEquivalent(
                key: "]",
                mask: [.command, .option]
            ),
            #selector(PanelViewController.moveTabToOtherPanel(_:)): KeyEquivalent(
                key: "m",
                mask: [.command, .shift]
            )
        ]
        for (action, equivalent) in expected {
            let item = try #require(items.first { $0.action == action }, "\(action)")
            #expect(item.keyEquivalent == equivalent.key)
            #expect(item.keyEquivalentModifierMask == equivalent.mask)
        }
    }

    private struct KeyEquivalent {
        let key: String
        let mask: NSEvent.ModifierFlags
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }

    // MARK: - Dropping a chip

    private func chipFrame(_ index: Int, in bar: TabBarView) -> NSRect {
        bar.chips[index].convert(bar.chips[index].bounds, to: bar)
    }

    /// A drag of chip `index` of `source`, with the pointer over `bar` at `x` in its coordinates.
    private func drag(_ index: Int, of source: TabBarView, over bar: TabBarView, atX x: CGFloat) -> TabDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.tab-drag"))
        board.clearContents()
        board.setString(String(index), forType: TabBarView.tabDragType)
        let location = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
        return TabDraggingInfo(board: board, source: source, location: location)
    }

    /// The bug the first strip shipped: released in the gap before gamma, alpha landed after it.
    @Test("a chip dropped along its own strip lands in the gap the marker showed")
    func dropAlongTheStrip() async throws {
        let panes = try await makePanes()
        let bar = panes.left.pane.tabBar
        // Left of gamma's middle and right of beta's: the gap between the two.
        let info = drag(0, of: bar, over: bar, atX: chipFrame(2, in: bar).minX + 1)

        #expect(bar.dropOperation(for: info) == .move)
        #expect(!bar.insertionMarker.isHidden)
        #expect(bar.performDragOperation(info))

        #expect(panes.leftPaths == [Self.beta, Self.alpha, Self.gamma])
        #expect(panes.left.pane.panel.path == Self.gamma)
        #expect(bar.insertionMarker.isHidden)
    }

    @Test("a drop that would leave the chip where it is is refused, with no marker")
    func noOpDropIsRefused() async throws {
        let panes = try await makePanes()
        let bar = panes.left.pane.tabBar
        // Beta nudged right, still left of gamma's middle.
        let info = drag(1, of: bar, over: bar, atX: chipFrame(1, in: bar).maxX - 1)

        #expect(bar.dropOperation(for: info).isEmpty)
        #expect(bar.insertionMarker.isHidden)
        #expect(!bar.performDragOperation(info))
        #expect(panes.leftPaths == [Self.alpha, Self.beta, Self.gamma])
    }

    @Test("dragging a chip shows the other pane's one-tab strip, and a drop there moves the tab")
    func dropOnTheOtherStrip() async throws {
        let panes = try await makePanes()
        let (source, target) = (panes.left.pane.tabBar, panes.right.pane.tabBar)
        #expect(target.isHidden)

        panes.left.pane.tabBar(source, tabDragIsInFlight: true)
        #expect(!target.isHidden)
        panes.right.window.layoutIfNeeded()
        // Past the middle of the only chip: the gap after it.
        let info = drag(0, of: source, over: target, atX: chipFrame(0, in: target).maxX + 2)
        #expect(target.dropOperation(for: info) == .move)
        #expect(target.performDragOperation(info))
        panes.left.pane.tabBar(source, tabDragIsInFlight: false)

        #expect(panes.rightPaths == [Self.other, Self.alpha])
        #expect(panes.right.pane.panel.path == Self.alpha)
        #expect(panes.leftPaths == [Self.beta, Self.gamma])
        #expect(panes.left.pane.panel.path == Self.gamma)
        #expect(!target.isHidden)
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)
    }

    @Test("a drag that ends without a drop hides the one-tab strip again")
    func revealIsUndone() async throws {
        let panes = try await makePanes()
        let (source, target) = (panes.left.pane.tabBar, panes.right.pane.tabBar)
        panes.left.pane.tabBar(source, tabDragIsInFlight: true)
        #expect(!target.isHidden)
        panes.left.pane.tabBar(source, tabDragIsInFlight: false)
        #expect(target.isHidden)
        #expect(panes.rightPaths == [Self.other])
    }

    @Test("anything that is not a tab chip is not accepted by a strip")
    func otherDragsAreRefused() async throws {
        let panes = try await makePanes()
        let bar = panes.left.pane.tabBar
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.tab-drag"))
        board.clearContents()
        board.setString("0", forType: TabBarView.tabDragType)
        // The right type, but from no strip: not a chip of this window.
        let stray = TabDraggingInfo(board: board, source: nil, location: .zero)
        #expect(bar.dropOperation(for: stray).isEmpty)
        #expect(!bar.performDragOperation(stray))
        #expect(panes.leftPaths == [Self.alpha, Self.beta, Self.gamma])
    }

    /// The trap docs/NOTES.md ▸ Delegates in Swift 6 records: an optional `@objc` requirement on a
    /// main-actor class can conform and never be emitted, and then AppKit never calls it. Asserted
    /// by selector string, since `#selector(Protocol.method)` keeps naming it whether or not it is.
    @Test("the strip's drag-session callbacks are real Objective-C methods")
    func draggingSourceSelectorsAreEmitted() {
        for name in [
            "draggingSession:sourceOperationMaskForDraggingContext:",
            "draggingSession:willBeginAtPoint:",
            "draggingSession:endedAtPoint:operation:"
        ] {
            #expect(TabBarView.instancesRespond(to: Selector(name)), "\(name)")
        }
    }

    @Test("a chip's drag image is opaque, even for a tab with no fill of its own")
    func dragImageIsOpaque() async throws {
        let panes = try await makePanes()
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
        let panes = try await makePanes()
        let bar = panes.left.pane.tabBar
        let menu = bar.chipMenu(for: bar.chips[0])
        let move = try #require(menu.items.first)
        let close = try #require(menu.items.last)
        #expect(move.title == LocalizedCatalog.command(for: "window.moveTabToOtherPanel")?.title)
        #expect(close.title == LocalizedCatalog.command(for: "file.closeTab")?.title)
        // The command's key acts on the tab showing, so the chip's item must not advertise it.
        #expect(move.keyEquivalent.isEmpty)

        #expect(NSApp.sendAction(try #require(move.action), to: move.target, from: move))
        #expect(panes.rightPaths == [Self.other, Self.alpha])
        #expect(panes.leftPaths == [Self.beta, Self.gamma])
        #expect(panes.left.pane.panel.path == Self.gamma)

        let closeBeta = try #require(bar.chipMenu(for: bar.chips[0]).items.last)
        #expect(
            NSApp.sendAction(try #require(closeBeta.action), to: closeBeta.target, from: closeBeta)
        )
        #expect(panes.leftPaths == [Self.gamma])
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
