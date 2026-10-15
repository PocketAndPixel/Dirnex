import AppKit
import Testing

@testable import Dirnex

/// The strip across the top of the full-screen surface (`QuickViewPreviewView+TopStrip`): a
/// document starts below it and a picture runs to the top edge under it.
///
/// Reported 2026-10-15: the first line of a text file in full screen could not be selected. The
/// floating header covers it (and answers clicks even at zero alpha), and so does the system's
/// title bar once the pointer reaches the top of the screen.
@MainActor
@Suite("Quick View ▸ the full-screen surface's top strip")
struct QuickViewTopStripTests {
    @Test("a document starts below the floating header")
    func documentStartsBelowTheHeader() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "first line\nsecond line\n")
        let hosted = try await Self.hosted(url, header: .floating)
        let preview = hosted.preview

        #expect(Self.topOffset(of: preview.content, in: preview) == QuickViewHeaderView.height)
    }

    /// The bug itself, as the mouse meets it. The point is worked out from the text view's own first
    /// line rather than from a fixed depth, so with the strip gone it lands under the header, which
    /// takes it.
    @Test("a click on the first line reaches the text, and a click in the strip does not")
    func firstLineTakesTheMouse() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "first line\nsecond line\n")
        let hosted = try await Self.hosted(url, header: .floating)
        let preview = hosted.preview
        let textView = try #require(preview.textSurface?.textView)
        let container = try #require(preview.superview)

        let origin = textView.textContainerOrigin
        let firstLine = textView.convert(NSPoint(x: origin.x + 4, y: origin.y + 4), to: container)
        let lineHit = try #require(preview.hitTest(firstLine))
        #expect(QuickViewTextPreviewTests.enclosingTextView(of: lineHit) === textView)

        let strip = NSPoint(x: firstLine.x, y: container.bounds.maxY - 4)
        let stripHit = preview.hitTest(strip)
        #expect(stripHit.flatMap(QuickViewTextPreviewTests.enclosingTextView(of:)) == nil)
    }

    /// A display without a camera housing: the menu bar comes down over the window and pushes the
    /// title bar down by its own height, so the strip has to deepen by as much.
    @Test("the strip deepens by a menu bar that comes down over the window")
    func stripDeepensByTheMenuBar() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "first line\n")
        let hosted = try await Self.hosted(url, header: .floating)
        let preview = hosted.preview

        preview.menuBarOverlap = 24
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.topOffset(of: preview.content, in: preview) == QuickViewHeaderView.height + 24)

        preview.menuBarOverlap = 0
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.topOffset(of: preview.content, in: preview) == QuickViewHeaderView.height)
    }

    /// Decided by the file's kind as `show` routes it, so the bytes do not need to decode: the strip
    /// is settled before the backend reads anything.
    @Test("a picture runs to the top edge, and the next document comes back below the strip")
    func pictureRunsToTheTop() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let photo = try tree.write("photo.png", contents: "x")
        let notes = try tree.write("notes.txt", contents: "first line\n")
        let hosted = try await Self.hosted(notes, header: .floating)
        let preview = hosted.preview
        preview.menuBarOverlap = 24

        preview.show(photo, style: .default)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.topOffset(of: preview.content, in: preview) == 0)

        preview.show(notes, style: .default)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.topOffset(of: preview.content, in: preview) == QuickViewHeaderView.height + 24)
    }

    /// The working surfaces take a strip of their own under a pinned header, below the title bar's
    /// safe area, and nothing ever drops over them.
    @Test("a pinned header's surface is left as it was")
    func pinnedSurfaceUnchanged() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "first line\n")
        let hosted = try await Self.hosted(url, header: .pinned)
        let preview = hosted.preview

        preview.menuBarOverlap = 24
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(Self.topOffset(of: preview.content, in: preview) == QuickViewHeaderView.height)
    }

    // MARK: - Helpers

    /// A surface in a window, showing `url` once its text backend is up. The window is returned
    /// beside it so it lives as long as the test does.
    static func hosted(
        _ url: URL,
        header: QuickViewPreviewView.Header
    ) async throws -> (preview: QuickViewPreviewView, window: NSWindow) {
        let preview = QuickViewPreviewView(
            backingColor: .black,
            header: header,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        preview.show(url, style: .source)
        // The read runs off the main actor, so yield until the text surface is up rather than
        // spinning the run loop (`QuickViewTextPreviewTests.loaded` carries the full account).
        for _ in 0..<60 {
            if preview.textSurface?.isHidden == false { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(preview.textSurface?.isHidden == false)
        content.layoutSubtreeIfNeeded()
        return (preview, window)
    }

    /// How far below `container`'s top edge `view` starts, whichever way either is flipped.
    static func topOffset(of view: NSView, in container: NSView) -> CGFloat {
        let frame = view.convert(view.bounds, to: container)
        return container.isFlipped ? frame.minY : container.bounds.maxY - frame.maxY
    }
}
