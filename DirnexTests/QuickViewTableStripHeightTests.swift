import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Dragging the edge between Quick View's table and its strip (2026-09-15): the strip fits its row
/// until somebody drags it, keeps a dragged height for every row and file after that, leaves the table
/// room for its header, and goes back to fitting its row on a double-click.
///
/// The drag is driven through the handle's own mouse handlers with events built in the window's
/// coordinates, which is the route a real drag takes once the preview has handed the handle the mouse
/// (the hit-test test pins that half).
@Suite("Quick View table strip height")
@MainActor
struct QuickViewTableStripHeightTests {
    private static let sample = (1...40).map { "item\($0),\($0 * 7),note \($0)" }
        .joined(separator: "\n")

    @Test(
        "an undragged strip fits its row, and a dragged height holds within the room the table keeps"
    )
    func heightRule() {
        typealias Table = QuickViewTableView
        #expect(Table.stripHeight(chosen: nil, fitting: 60, surface: 400) == 60)
        #expect(Table.stripHeight(chosen: nil, fitting: 300, surface: 400) == 160)
        #expect(Table.stripHeight(chosen: 200, fitting: 60, surface: 400) == 200)
        #expect(
            Table.stripHeight(chosen: 390, fitting: 60, surface: 400) == 400 - Table.minimumTableHeight
        )
        #expect(Table.stripHeight(chosen: 5, fitting: 60, surface: 400) == Table.minimumStripHeight)
        #expect(Table.stripHeight(chosen: 200, fitting: 60, surface: 30) == 30)
    }

    @Test(
        "dragging the edge up grows the strip as far as the pointer moved, and the table gives way"
    )
    func dragGrowsTheStrip() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        let fitting = surface.strip.fittingHeight(forWidth: surface.bounds.width)
        let before = surface.strip.frame.height
        #expect(abs(before - fitting) <= 1)
        #expect(surface.chosenStripHeight == nil)

        try Self.drag(surface, by: 90)
        #expect(abs(surface.strip.frame.height - (before + 90)) <= 1)
        #expect(abs(surface.scrollView.frame.minY - surface.strip.frame.maxY) <= 1)
        let kept = try #require(surface.chosenStripHeight)
        #expect(abs(kept - (before + 90)) <= 1)
        #expect(surface.layoutDefaults.object(forKey: QuickViewTableView.stripHeightKey) != nil)

        try Self.drag(surface, by: -40)
        #expect(abs(surface.strip.frame.height - (before + 50)) <= 1)
    }

    @Test("a dragged height holds for another row, another file, and another preview")
    func draggedHeightHolds() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        try Self.drag(surface, by: 120)
        let dragged = surface.strip.frame.height

        // A row needing far more room than the dragged height does not move the edge.
        let wide = String(repeating: "a long note ", count: 60)
        let next = try #require(
            DelimitedTable.parse("name,value,note\nfirst,1,\(wide)\nsecond,2,x\n")
        )
        surface.show(next, isTruncated: false)
        surface.superview?.layoutSubtreeIfNeeded()
        #expect(surface.strip.fittingHeight(forWidth: surface.bounds.width) > dragged + 50)
        #expect(abs(surface.strip.frame.height - dragged) <= 1)
        surface.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        surface.superview?.layoutSubtreeIfNeeded()
        #expect(abs(surface.strip.frame.height - dragged) <= 1)

        // Quick View's other sizes are other previews, which read the same store.
        let other = try await QuickViewTableFixtures.loaded(
            try fixture.tree.write("other.csv", contents: "a,b\n1,2\n"),
            layoutDefaults: surface.layoutDefaults
        )
        let otherSurface = try #require(other.tableSurface)
        #expect(abs(otherSurface.strip.frame.height - dragged) <= 1)
    }

    @Test("a drag past either end leaves the table its header and the strip a line")
    func dragIsBounded() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        try Self.drag(surface, by: 2000)
        let tableRoom = QuickViewTableView.minimumTableHeight
        #expect(abs(surface.strip.frame.height - (surface.bounds.height - tableRoom)) <= 1)
        #expect(abs(surface.scrollView.frame.height - tableRoom) <= 1)

        try Self.drag(surface, by: -2000)
        #expect(abs(surface.strip.frame.height - QuickViewTableView.minimumStripHeight) <= 1)
    }

    @Test("a double-click on the edge goes back to fitting the row")
    func doubleClickFitsTheRow() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let surface = fixture.surface
        let fitting = surface.strip.frame.height
        try Self.drag(surface, by: 150)
        #expect(surface.chosenStripHeight != nil)

        let handle = surface.stripHandle
        let window = try #require(handle.window)
        let point = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        handle.mouseDown(with: try Self.event(.leftMouseDown, at: point, in: window, clicks: 2))
        handle.mouseUp(with: try Self.event(.leftMouseUp, at: point, in: window, clicks: 2))
        surface.superview?.layoutSubtreeIfNeeded()
        #expect(surface.chosenStripHeight == nil)
        #expect(surface.layoutDefaults.object(forKey: QuickViewTableView.stripHeightKey) == nil)
        #expect(abs(surface.strip.frame.height - fitting) <= 1)
    }

    /// The preview takes the mouse for the whole surface except its interactive backends, so the
    /// handle is only draggable if the table's exemption reaches it.
    @Test("the preview hands the edge the mouse, and there is no edge without a selected row")
    func handleTakesTheMouse() async throws {
        let fixture = try await Self.table()
        defer { fixture.tree.cleanup() }
        let (preview, surface) = (fixture.preview, fixture.surface)
        let handle = surface.stripHandle
        #expect(!handle.isHidden)
        let point = handle.convert(
            NSPoint(x: handle.bounds.midX, y: handle.bounds.midY),
            to: preview.superview
        )
        #expect(preview.hitTest(point) === handle)

        // The edge reaches down into the strip, not up into the table's last row.
        let strip = surface.strip.frame
        #expect(handle.frame.intersection(surface.scrollView.frame).height <= 0.5)
        let justAbove = surface.convert(
            NSPoint(x: strip.midX, y: surface.isFlipped ? strip.minY - 2 : strip.maxY + 2),
            to: preview.superview
        )
        let aboveHit = try #require(preview.hitTest(justAbove))
        #expect(aboveHit.isDescendant(of: surface.scrollView))

        // Tall enough to aim at, over no view that sets a cursor of its own: a text view under it
        // takes the cursor back everywhere but the separator.
        #expect(handle.frame.height >= 12)
        let text = try #require(Self.textView(in: surface.strip)?.enclosingScrollView)
        let textFrame = text.convert(text.bounds, to: surface)
        #expect(handle.frame.intersection(textFrame).height <= 0.5)

        // The blank room the handle lies over is painted by the strip, not left to the backing.
        let rep = try #require(
            surface.strip.bitmapImageRepForCachingDisplay(in: surface.strip.bounds)
        )
        surface.strip.cacheDisplay(in: surface.strip.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / surface.strip.bounds.height
        let gap = try #require(rep.colorAt(
            x: rep.pixelsWide / 2,
            y: Int((1 + QuickViewRecordStrip.handleRoom / 2) * scale)
        ))
        #expect(gap.alphaComponent > 0.99)

        surface.tableView.deselectAll(nil)
        surface.superview?.layoutSubtreeIfNeeded()
        #expect(surface.strip.frame.height == 0)
        #expect(handle.isHidden)
    }

    // MARK: - Helpers

    private struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewTableView
        let tree: TempDirectory
    }

    private static func table(function: String = #function) async throws -> Fixture {
        let tree = try TempDirectory()
        let preview = try await QuickViewTableFixtures.loaded(
            try tree.write("strip.csv", contents: "name,value,note\n\(sample)\n"),
            function: function
        )
        return Fixture(preview: preview, surface: try #require(preview.tableSurface), tree: tree)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    /// Drag the strip's edge `distance` points up (down for a negative one), in two steps.
    private static func drag(_ surface: QuickViewTableView, by distance: CGFloat) throws {
        let handle = surface.stripHandle
        let window = try #require(handle.window)
        let start = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        handle.mouseDown(with: try event(.leftMouseDown, at: start, in: window))
        for step in [distance / 2, distance] {
            let point = NSPoint(x: start.x, y: start.y + step)
            handle.mouseDragged(with: try event(.leftMouseDragged, at: point, in: window))
        }
        handle.mouseUp(
            with: try event(.leftMouseUp, at: NSPoint(x: start.x, y: start.y + distance), in: window)
        )
        surface.superview?.layoutSubtreeIfNeeded()
    }

    private static func event(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow,
        clicks: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        ))
    }
}
