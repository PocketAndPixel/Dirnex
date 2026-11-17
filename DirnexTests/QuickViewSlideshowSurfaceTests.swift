import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// What the slideshow needs from everything around it (PLAN.md §M39 ▸ Slice 16): the size ⇧⌘S opens,
/// a surface that says when its picture has arrived, the header's mark and the interval setting.
@Suite("Quick View slideshow ▸ the window, the surface, the header and the setting")
@MainActor
struct QuickViewSlideshowSurfaceTests {
    // MARK: - The size

    /// Oleg's call: ⇧⌘S works from anywhere, opening full screen as Preview's Slideshow does, and runs
    /// in full window when that is up.
    @Test("⇧⌘S opens full screen from the list or the pane, and keeps a full size already up")
    func sizeItRunsAt() {
        #expect(BrowserWindowController.slideshowMode(from: .off) == .fullScreen)
        #expect(BrowserWindowController.slideshowMode(from: .pane) == .fullScreen)
        #expect(BrowserWindowController.slideshowMode(from: .fullWindow) == .fullWindow)
        #expect(BrowserWindowController.slideshowMode(from: .fullScreen) == .fullScreen)
    }

    @Test("the command is wired to the window's selector")
    func commandIsWired() {
        #expect(
            CommandBinding.selector(for: "view.quickViewSlideshow")
                == #selector(BrowserWindowController.toggleQuickViewSlideshow(_:))
        )
    }

    // MARK: - When the picture has arrived

    private func surface() -> QuickViewPreviewView {
        let view = QuickViewPreviewView(
            backingColor: .black,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        return view
    }

    @Test("a backend still loading is awaited, and its arrival is announced once")
    func loadingIsAwaitedAndAnnounced() {
        let view = surface()
        var announced = 0
        view.onContentDidLoad = { announced += 1 }
        #expect(!view.isAwaitingContent)
        view.flipGate.isLoading = true
        #expect(view.isAwaitingContent)
        view.contentDidLoad()
        #expect(!view.isAwaitingContent)
        #expect(announced == 1)
    }

    /// A card whose download is running is a picture on its way; any other card is all there will be,
    /// and a show that waited on it would stop at a file too large to fetch unasked.
    @Test("a download card is awaited, a card waiting to be asked is not")
    func downloadCardIsAwaited() {
        let view = surface()
        view.show(nil, style: .default, placeholder: Self.card(.downloading))
        #expect(view.isAwaitingContent)
        view.show(nil, style: .default, placeholder: Self.card(.awaitingRequest(.tooLarge)))
        #expect(!view.isAwaitingContent)
        view.show(nil, style: .default, placeholder: Self.card(.failed))
        #expect(!view.isAwaitingContent)
    }

    @Test("a real picture is awaited until it has decoded")
    func realPictureIsAwaited() async throws {
        let view = surface()
        var announced = 0
        view.onContentDidLoad = { announced += 1 }
        view.show(Self.imageFile, style: .default)
        #expect(view.isAwaitingContent, "the image backend reads and decodes off the main actor")
        try await settleUntil { announced == 1 }
        #expect(!view.isAwaitingContent)
    }

    private static func card(_ state: RemotePreviewPlaceholder.State) -> RemotePreviewPlaceholder {
        RemotePreviewPlaceholder(
            name: "DSC_0002.NEF", size: "29 MB", byteSize: 29_000_000, state: state
        )
    }

    /// Any real file the image backend takes.
    private static let imageFile = Bundle(for: QuickViewPreviewView.self).bundleURL
        .appendingPathComponent("Contents/Resources/AppIcon.icns")

    // MARK: - The header's mark

    @Test("the header marks a running show beside the position, and a click on the mark stops it")
    func headerMark() throws {
        let hosted = try QuickViewCloseButtonTests.hosted(header: .pinned)
        var stops = 0
        hosted.preview.onStopSlideshow = { stops += 1 }
        var caption = QuickViewCaption(name: "1.jpg", position: 1, count: 5)
        hosted.preview.setCaption(caption)
        let header = try QuickViewCloseButtonTests.header(of: hosted.preview)
        #expect(header.slideshowButton.isHidden)

        caption.isSlideshowRunning = true
        hosted.preview.setCaption(caption)
        hosted.window.contentView?.layoutSubtreeIfNeeded()
        #expect(!header.slideshowButton.isHidden)
        let position = QuickViewCloseButtonTests.laidOut(
            try QuickViewCloseButtonTests.label(in: header, reading: caption.positionText)
        )
        let mark = QuickViewCloseButtonTests.laidOut(header.slideshowButton)
        #expect(mark.maxX <= position.minX - 9, "the mark sits before the position, clear of it")
        #expect(position.maxX == header.bounds.maxX - 12, "the position keeps its place at the edge")
        #expect(header.slideshowButton.refusesFirstResponder)

        header.slideshowButton.performClick(nil)
        #expect(stops == 1)

        caption.isSlideshowRunning = false
        hosted.preview.setCaption(caption)
        #expect(header.slideshowButton.isHidden)
    }

    // MARK: - The setting

    @Test("the interval is Preview's five seconds on a fresh install, held to its range, and kept")
    func intervalSetting() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.slideshowInterval == 5)

        preferences.slideshowInterval = 0
        #expect(preferences.slideshowInterval == 1)
        preferences.slideshowInterval = 600
        #expect(preferences.slideshowInterval == 60)
        preferences.slideshowInterval = 8
        #expect(AppPreferences(defaults: defaults).slideshowInterval == 8)

        defaults.set(-3, forKey: AppPreferences.Keys.slideshowInterval)
        let edited = AppPreferences(defaults: defaults)
        #expect(edited.slideshowInterval == 1, "a hand edit is clamped too")
    }
}
