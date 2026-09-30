import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// ⌘+, ⌘− and ⌘0 on an image in Quick View (2026-09-15): a photograph opens fitted, steps along the
/// ladder as absolute scales so actual size is reachable, pans once it is wider than the surface, and
/// goes back to its fit on ⌘0 (`QuickViewImageScrollView`).
@Suite("Quick View image zoom")
@MainActor
struct QuickViewImageZoomTests {
    @Test("a large photo opens fitted, steps up the ladder from its fit, pans, and ⌘0 refits it")
    func largeImageZooms() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try QuickViewZoomFixtures.png(width: 4000, height: 2000, in: tree),
            style: .source
        )
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)
        // 400 / 4000: fitted, as the old view drew it, and nothing to pan.
        #expect(abs(scrollView.magnification - 0.1) < 0.001)
        #expect(!preview.consumesHorizontalScroll)
        #expect(!preview.canResetZoom)
        #expect(!preview.canZoom(.smaller), "a photo fitted below the ladder has no smaller step")

        preview.zoom(.larger)
        #expect(abs(scrollView.magnification - 0.25) < 0.001)
        #expect(preview.consumesHorizontalScroll, "a zoomed photo pans instead of flipping files")
        #expect(preview.canResetZoom)

        preview.resetZoom()
        #expect(abs(scrollView.magnification - 0.1) < 0.001)
        #expect(!preview.consumesHorizontalScroll)
    }

    @Test("a small image is never blown up to open, and zooms either way from its own size")
    func smallImageZooms() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(try QuickViewZoomFixtures.png(width: 40, height: 40, in: tree), style: .source)
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)
        #expect(abs(scrollView.magnification - 1) < 0.001)

        preview.zoom(.larger)
        #expect(abs(scrollView.magnification - 1.1) < 0.001)
        preview.resetZoom()
        preview.zoom(.smaller)
        #expect(abs(scrollView.magnification - 0.9) < 0.001)
    }

    @Test("a resize refits a photo nobody zoomed and keeps the scale of one somebody did")
    func resizeRefitsOnlyAnUnzoomedImage() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try QuickViewZoomFixtures.png(width: 4000, height: 2000, in: tree),
            style: .source
        )
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)
        let window = try #require(preview.window)

        window.setContentSize(NSSize(width: 800, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(scrollView.magnification - 0.2) < 0.001)

        preview.zoom(.larger)
        let zoomed = scrollView.magnification
        window.setContentSize(NSSize(width: 600, height: 400))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(abs(scrollView.magnification - zoomed) < 0.001)
    }

    @Test("the next image opens fitted again, whatever the last one was zoomed to")
    func nextImageStartsFitted() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try QuickViewZoomFixtures.png(width: 4000, height: 2000, in: tree),
            style: .source
        )
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)
        preview.zoom(.larger)
        preview.zoom(.larger)

        preview.show(
            try QuickViewZoomFixtures.png(width: 800, height: 800, name: "second.png", in: tree),
            style: .source
        )
        try await QuickViewZoomFixtures.settle { scrollView.imageView.image?.size.width == 800 }
        #expect(abs(scrollView.magnification - 0.5) < 0.001)
        #expect(!preview.canResetZoom)
    }

    /// A zoomed photo has to be panned and pinched, so the surface lets the mouse reach it — where it
    /// used to swallow every event over an image.
    @Test("the mouse reaches a photo's scroll view")
    func imageKeepsTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try QuickViewZoomFixtures.png(width: 4000, height: 2000, in: tree),
            style: .source
        )
        let scrollView = try await QuickViewZoomFixtures.imageScrollView(in: preview)
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(hit === scrollView || hit.isDescendant(of: scrollView))
    }
}
