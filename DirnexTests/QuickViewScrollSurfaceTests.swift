import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What a scroll move does to each Quick View backend that scrolls through its own scroll view
/// (2026-10-18): text, a CSV table, a JSON tree and a zoomed image. The PDF and the web backends are
/// `QuickViewScrollPageTests`'; which key asks for which move is `QuickViewScrollKeysTests`'; the
/// distances are `DirnexCore`'s (`QuickViewScroll`).
@Suite("Quick View scroll surfaces", .serialized)
@MainActor
struct QuickViewScrollSurfaceTests {
    // MARK: - Scroll views

    /// The steps, both ends, and the clamp at each end, over any backend whose document is flipped.
    private func walksAFlippedDocument(
        _ preview: QuickViewPreviewView,
        scrollView: NSScrollView,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let clip = scrollView.contentView
        let document = try #require(scrollView.documentView, sourceLocation: sourceLocation)
        try #require(document.isFlipped, sourceLocation: sourceLocation)
        try #require(
            document.frame.height > clip.bounds.height * 3,
            "the fixture must be several screens long",
            sourceLocation: sourceLocation
        )
        let rest = clip.bounds.origin.y

        preview.scrollContent(.end)
        let end = clip.bounds.origin.y
        #expect(
            scrollView.documentVisibleRect.maxY >= document.frame.maxY - 1,
            "the end shows the document's last point",
            sourceLocation: sourceLocation
        )
        preview.scrollContent(.lineDown)
        #expect(
            clip.bounds.origin.y == end,
            "a step past the end stays at it",
            sourceLocation: sourceLocation
        )

        // The top is where the view first rested, which is not necessarily an origin of 0.
        preview.scrollContent(.top)
        #expect(clip.bounds.origin.y == rest, sourceLocation: sourceLocation)
        preview.scrollContent(.pageUp)
        #expect(
            clip.bounds.origin.y == rest,
            "a step past the top stays at it",
            sourceLocation: sourceLocation
        )

        preview.scrollContent(.lineDown)
        #expect(
            clip.bounds.origin.y == rest + QuickViewScrollFixtures.lineStep,
            sourceLocation: sourceLocation
        )
        // A page is measured over what is seen between the two resting places, not the clip's height.
        let seen = document.frame.height - (end - rest)
        let page = CGFloat(QuickViewScroll.pageStep(visibleHeight: seen))
        preview.scrollContent(.pageDown)
        #expect(
            clip.bounds.origin.y == rest + QuickViewScrollFixtures.lineStep + page,
            sourceLocation: sourceLocation
        )
        preview.scrollContent(.pageUp)
        preview.scrollContent(.lineUp)
        #expect(clip.bounds.origin.y == rest, sourceLocation: sourceLocation)
    }

    @Test("text steps a line and a page, reaches both ends and stops at them")
    func textScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        // Lines of uneven length, so TextKit 2's estimate of the height below the screen is not exact.
        let text = (1...3000).map { "line \($0) " + String(repeating: "word ", count: $0 * 7 % 40) }
            .joined(separator: "\n")
        let preview = try await QuickViewTextPreviewTests.loaded(
            tree.write("long.txt", contents: text)
        )
        let surface = try #require(preview.textSurface)
        let window = try await QuickViewScrollFixtures.drawn(preview) {
            surface.textView.frame.height > surface.scrollView.contentView.bounds.height * 3
        }
        defer { window.orderOut(nil) }
        try walksAFlippedDocument(preview, scrollView: surface.scrollView)

        // The end is the last character, not wherever the estimate put the bottom of the view.
        preview.scrollContent(.end)
        let layout = try #require(surface.textView.textLayoutManager)
        let storage = try #require(surface.textView.textContentStorage)
        layout.textViewportLayoutController.layoutViewport()
        let viewport = try #require(layout.textViewportLayoutController.viewportRange)
        #expect(
            storage.offset(from: storage.documentRange.location, to: viewport.endLocation)
                == (text as NSString).length
        )
    }

    /// The table's header floats over its rows, so the view rests above the document's origin — 60
    /// points in a full-size-content window — and a top worked out as origin 0 would hide row 1 under
    /// the header (docs/NOTES.md ▸ Tables). The fixture's window is that kind, so `rest` is negative.
    @Test("a CSV table scrolls, and its top leaves the first row clear of the header")
    func tableScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let csv = "name,value\n" + (1...300).map { "row \($0),\($0)" }.joined(separator: "\n")
        let preview = try await QuickViewTableFixtures.loaded(tree.write("data.csv", contents: csv))
        let surface = try #require(preview.tableSurface)
        let clip = surface.scrollView.contentView
        let covered = -clip.bounds.origin.y
        #expect(covered > 0)
        try walksAFlippedDocument(preview, scrollView: surface.scrollView)
        // The top it went back to is AppKit's own for the first row.
        let top = clip.bounds.origin.y
        surface.tableView.scrollRowToVisible(0)
        #expect(clip.bounds.origin.y == top)

        // What a page down is for: the row read last is still in view after it, below the header
        // rather than under it. Paged by the clip's own height, the header and title bar here cover
        // more than the line step's overlap, and that row disappears.
        let table = surface.tableView
        func rowsInView() -> ClosedRange<Int> {
            let visible = surface.scrollView.documentVisibleRect
            let first = table.row(at: NSPoint(x: 1, y: visible.minY + covered + 0.5))
            let last = table.row(at: NSPoint(x: 1, y: visible.maxY - 0.5))
            return first...last
        }
        for _ in 0..<3 {
            let before = rowsInView()
            preview.scrollContent(.pageDown)
            let after = rowsInView()
            #expect(after.lowerBound > before.lowerBound)
            #expect(after.contains(before.upperBound))
        }
    }

    @Test("a JSON tree scrolls")
    func treeScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let keys = (1...300).map { "\"key\($0)\": \($0)" }.joined(separator: ",\n")
        let preview = try await QuickViewTableFixtures.loaded(
            tree.write("big.json", contents: "{\n\(keys)\n}")
        )
        let surface = try #require(preview.treeSurface)
        try #require(surface.outlineView.numberOfRows > 100)
        try walksAFlippedDocument(preview, scrollView: surface.scrollView)
    }

    // MARK: - Image

    @Test("a zoomed image scrolls between its top and bottom edges; a fitted one stays put")
    func imageScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try QuickViewZoomFixtures.png(width: 1200, height: 1200, in: tree),
            style: .source
        )
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)

        // Fitted, there is nowhere to go: the origin moves by rounding at most.
        let fitted = scrollView.contentView.bounds.origin
        preview.scrollContent(.lineDown)
        preview.scrollContent(.end)
        let moved = scrollView.contentView.bounds.origin
        #expect(abs(moved.x - fitted.x) < 0.01 && abs(moved.y - fitted.y) < 0.01)

        scrollView.setZoomLevel(1)
        scrollView.layoutSubtreeIfNeeded()
        // An image view is not flipped: its top edge is its frame's maxY.
        let image = scrollView.imageView.frame
        try #require(!scrollView.imageView.isFlipped)
        preview.scrollContent(.top)
        #expect(abs(scrollView.documentVisibleRect.maxY - image.maxY) < 1)
        preview.scrollContent(.lineDown)
        #expect(
            abs(
                scrollView.documentVisibleRect.maxY - (image.maxY - QuickViewScrollFixtures.lineStep)
            ) < 1
        )
        preview.scrollContent(.end)
        #expect(abs(scrollView.documentVisibleRect.minY - image.minY) < 1)
    }

    // MARK: - What does not scroll

    @Test("over Quick Look's own view a move does nothing, and asks for nothing")
    func quickLookDoesNotScroll() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(try tree.write("clip.mp4", contents: "not really a movie"), style: .source)
        #expect(preview.contentTarget == nil)
        for move in QuickViewScroll.allCases {
            preview.scrollContent(move)
        }
    }
}

/// What both scroll suites share.
@MainActor
enum QuickViewScrollFixtures {
    static let lineStep = CGFloat(QuickViewScroll.lineStep)

    /// Put the preview's window on screen and wait until `ready`. A text view in TextKit 2 sizes itself
    /// for the whole document only once it has been on screen through a run-loop turn (measured here:
    /// 394 points for 3000 lines, one screen, until then), and `PDFView` reports no visible pages until
    /// it has — as it is in the app, where the preview is on screen before anyone can press a key at it.
    /// Waited for by sleeping, which lets the main run loop turn, rather than by spinning it
    /// (docs/NOTES.md ▸ Testing).
    static func drawn(
        _ preview: QuickViewPreviewView,
        until ready: () -> Bool
    ) async throws -> NSWindow {
        let window = try #require(preview.window)
        window.orderFront(nil)
        let deadline = Date().addingTimeInterval(10)
        while !ready() {
            try #require(Date() < deadline, "the preview never finished drawing")
            try await Task.sleep(for: .milliseconds(10))
        }
        preview.layoutSubtreeIfNeeded()
        return window
    }
}
