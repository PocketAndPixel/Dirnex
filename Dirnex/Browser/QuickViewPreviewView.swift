import AppKit
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// How large the Quick View preview is, and therefore what it is anchored over (PLAN.md §M11).
/// Owned by `BrowserWindowController` — the mode spans both panes and follows the active one, so
/// no single pane can hold it. Every size drives the same `QuickViewPreviewView`; only the anchor,
/// the backing colour and the header differ.
enum QuickViewMode {
    /// No preview anywhere; the two panes show their file lists.
    case off
    /// ⌃Q — the *inactive* pane shows the preview (PLAN.md §M4).
    case pane
    /// ⌃⇧Q — the preview spans both panes and the divider. A working mode: the sidebar, the
    /// terminal drawer and the function bar stay where they were.
    case fullWindow
    /// ⌃⌥Q — the preview fills the window's content view and the window enters the native
    /// full-screen space. A viewing mode: black backing, no chrome.
    case fullScreen

    /// Whether this size covers the file list the cursor is walking, which is what makes a header
    /// and the ← / → cursor steps necessary rather than redundant.
    var isFullSize: Bool { self == .fullWindow || self == .fullScreen }
}

/// One Quick View preview surface: an opaque backing, the two preview backends that share it, and
/// an optional name-and-position header. Extracted from `PanelViewController+QuickView` when §M11
/// gave the mode two larger sizes — the pane keeps one of these pinned over its scroll view, and
/// each full mode hosts an identical one at a different anchor, so there is one preview
/// implementation rather than three.
///
/// Two backends because Quick Look only wires up magnify-to-zoom for *single-page* PDFs, so a
/// multi-page document can't be magnified through it. `PDFView` zooms and scrolls every PDF, so
/// PDFs route there and everything else goes to `QLPreviewView`.
@MainActor
final class QuickViewPreviewView: NSView {
    /// Whether this surface carries a header, and how it behaves.
    enum Header {
        /// No header — pane mode, where the file list is visible right beside the preview.
        case none
        /// Always visible, taking its own strip above the preview (full window: a working surface).
        case pinned
        /// Floating over the preview, fading in on mouse movement and back out after a pause
        /// (full screen: a viewing surface, where permanent chrome is the thing being escaped).
        case floating
    }

    /// The solid colour behind a preview that doesn't fill the view — a small image, a failed
    /// preview. Dynamic colours are honoured: this is re-resolved at draw time, where a captured
    /// `cgColor` would freeze at whichever appearance was current when it was taken.
    private let backingColor: NSColor
    private let headerStyle: Header
    private let headerView: QuickViewHeaderView?

    /// Where both backends are pinned. A separate view so a `.pinned` header can take a strip of
    /// its own above it while a `.floating` one overlaps it.
    /// Internal, not private: `QuickViewPreviewView+Swipe` slides this and Swift's `private`
    /// does not cross files.
    let content = NSView()

    private var previewView: QLPreviewView?
    private var pdfView: PDFView?
    private var imageView: NSImageView?
    /// The URL currently loaded, so an unrelated refresh that re-drives the same file is skipped
    /// instead of flickering the preview.
    private var loadedURL: URL?
    /// Set once the first `show` has run, so `show(nil)` on a fresh view still blanks the backends
    /// rather than being mistaken for "already showing nil".
    private var hasLoaded = false

    /// Bumped by every reveal of a `.floating` header, so a fade-out scheduled by an earlier
    /// mouse movement knows it has been superseded and stands down. A counter rather than a
    /// `Timer` because the timer's block is `@Sendable` and this view is not.
    private var headerFadeGeneration = 0
    private static let headerFadeDelay: TimeInterval = 2.5

    /// Bumped by every image load, so a slow one landing after the cursor moved on is discarded
    /// rather than replacing the file now on screen.
    private var imageToken = 0

    init(backingColor: NSColor, header: Header) {
        self.backingColor = backingColor
        headerStyle = header
        headerView = switch header {
        case .none: nil
        case .pinned: QuickViewHeaderView(material: .headerView)
        case .floating: QuickViewHeaderView(material: .hudWindow)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Not the default, and the difference is a whole-window bug: `draw(_:)` is handed a
        // `dirtyRect` that can be *larger* than the view's bounds, so a backing fill of it paints
        // over whatever sits beside the view. Caught live — the full-window preview blacked out
        // the sidebar and the function-key bar while its own frame was provably correct.
        clipsToBounds = true
        buildSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// Show `url`, routing it to the backend that fits. `nil` clears to a blank preview — the
    /// cursor is on `..` or in an empty directory, so there is nothing to show.
    func show(_ url: URL?) {
        guard url != loadedURL || !hasLoaded else { return }
        loadedURL = url
        hasLoaded = true
        if let url, Self.isPDF(url) {
            showPDF(url)
        } else if let url, Self.isImage(url) {
            showImage(url)
        } else {
            showQuickLook(url)
        }
    }

    /// Release both backends' loaded documents so nothing lingers in memory while the mode is off.
    /// Safe to call on a surface that never showed anything.
    func clear() {
        loadedURL = nil
        hasLoaded = false
        previewView?.previewItem = nil
        pdfView?.document = nil
        // Retire any pending fade-out: the surface is going away, and a stray one landing on the
        // next file would blank the header the moment it was shown.
        headerFadeGeneration += 1
        // A surface put away mid-swipe must not come back still shifted, or the next file opens
        // hanging off its edge with no gesture to bring it home.
        resetSwipe()
        imageView?.image = nil
    }

    /// The file the header names. Ignored when this surface has no header.
    func setCaption(_ caption: QuickViewCaption?) {
        headerView?.caption = caption
    }

    // MARK: - Appearance

    override var isOpaque: Bool { true }

    /// Refuse first responder so the arrow keys keep driving the file table underneath. In the
    /// full modes the preview sits over the *focused* table, and a surface that took focus on
    /// appearing would turn ↑/↓ into document scrolling — losing the mode's whole point silently.
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        backingColor.setFill()
        // Intersected with `bounds`, belt to `clipsToBounds`' braces: the rect AppKit hands over
        // is not promised to be inside the view.
        dirtyRect.intersection(bounds).fill()
    }

    /// Take the mouse for the whole surface, so nothing underneath can be clicked or dragged
    /// through it.
    ///
    /// Winning the hit test is *not* enough on its own, which is the trap here. `QLPreviewView`
    /// renders out of process, and its `QLLayerBasedPreviewContainerView` answers `hitTest` and then
    /// declines the event — AppKit re-dispatches to what is behind, so a click under a full-window
    /// preview moved the covered pane's cursor to the row beneath it and a drag copied a file to the
    /// other pane. Both are invisible while they happen. Returning `self` puts a view that *does*
    /// consume the event in front of the covered panes.
    ///
    /// `PDFView` is the deliberate exception: scrolling and pinch-zooming a document is the entire
    /// reason PDFs route there instead of to Quick Look, it is in-process, and it consumes what it
    /// handles. The header keeps the mouse for the same reason — it is this surface's own chrome.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if let hit = super.hitTest(point), hit.isInteractiveQuickViewBackend(
            pdf: pdfView,
            header: headerView
        ) {
            return hit
        }
        return self
    }

    // Swallow rather than forward: `NSResponder`'s default hands an unhandled click to the next
    // responder, and the point of taking it was that nobody else should act on it.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Backends

    /// Show `url` in the Quick Look backend, standing the others down.
    private func showQuickLook(_ url: URL?) {
        guard let preview = ensureQuickLookPreview() else { return }
        standDownPDF()
        standDownImage()
        preview.isHidden = false
        preview.previewItem = url as NSURL?
    }

    /// Show `url` in the plain `NSImageView` backend, standing the others down.
    ///
    /// Images bypass Quick Look deliberately (PLAN.md §M11). `QLPreviewView` renders in *another
    /// process*, so translating the layer that hosts it costs a round trip per frame — measured as
    /// a visibly juddering two-finger swipe, on exactly the content people swipe through most.
    /// An `NSImageView` is in-process, like the `PDFView` beside it, and the swipe runs at full rate.
    ///
    /// The bytes are read off the main actor so a large photo does not stall the flip; `Data` is
    /// `Sendable` where `NSImage` is not, which is why the image itself is built back here.
    private func showImage(_ url: URL) {
        let view = ensureImageView()
        standDownPDF()
        standDownQuickLook()
        view.isHidden = false
        imageToken += 1
        let token = imageToken
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }.value
            guard let self, token == imageToken else { return }
            view.image = data.flatMap(NSImage.init(data:))
        }
    }

    private func standDownQuickLook() {
        previewView?.isHidden = true
        previewView?.previewItem = nil
    }

    private func standDownPDF() {
        pdfView?.isHidden = true
        pdfView?.document = nil
    }

    private func standDownImage() {
        imageView?.isHidden = true
        imageView?.image = nil
    }

    /// Show `url` in the PDFKit backend, standing down the Quick Look one. `autoScales` refits the
    /// page to the surface for each new document; the user can then pinch to zoom in or out.
    private func showPDF(_ url: URL) {
        let pdfView = ensurePDFView()
        standDownQuickLook()
        standDownImage()
        pdfView.isHidden = false
        let document = PDFDocument(url: url)
        pdfView.document = document
        pdfView.autoScales = true
        // Rasterize page one *now* rather than letting PDFKit do it lazily. Parsing a PDF is
        // nearly free (measured 0.2 ms) but the first page render is not, and lazily it landed
        // ~30 ms into the swipe's flip animation and cost four frames of it — the judder was
        // reproducible on every flip into a PDF. Paid here it costs the same 3–8 ms while nothing
        // is moving. The thumbnail itself is discarded; warming the page cache is the point.
        _ = document?.page(at: 0)?.thumbnail(of: bounds.size, for: .mediaBox)
    }

    /// Whether `url` is a PDF, so it routes to `PDFView`. Prefers the file's real content type
    /// (catches an odd extension) and falls back to the extension when that can't be read.
    private static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    /// Whether `url` is an image, so it routes to the in-process `NSImageView`. Content type first
    /// (an odd extension still classifies), extension as the fallback.
    private static func isImage(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Build the image backend on first use. `scaleProportionallyDown` matches Quick Look: fit a
    /// large photo to the surface, but never blow a small one up past its own size.
    private func ensureImageView() -> NSImageView {
        if let imageView { return imageView }
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        // An `NSImageView`'s intrinsic content size is its *image*, and it defends that size at
        // priority 750 — so a wide photo pushes the whole constraint chain outwards and resizes the
        // **window**. A 8629 px panorama grew it past the edge of the display, cutting off the
        // function bar, with every frame in the preview itself still provably correct. The surface
        // is sized by its anchors alone; the image inside is a passenger.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentCompressionResistancePriority(.init(1), for: axis)
            view.setContentHuggingPriority(.init(1), for: axis)
        }
        pin(view, inside: content)
        imageView = view
        return view
    }

    /// Build the Quick Look backend on first use. `.compact` style drops Quick Look's
    /// title/controls chrome, which suits an always-on embedded preview. `init(frame:style:)` is
    /// failable, so this returns `nil` on the rare miss and the caller shows nothing.
    private func ensureQuickLookPreview() -> QLPreviewView? {
        if let preview = previewView { return preview }
        guard let preview = QLPreviewView(frame: .zero, style: .compact) else { return nil }
        // Closes automatically when the window goes away; this surface lives as long as the
        // window, so there is nothing to tear down by hand.
        preview.shouldCloseWithWindow = true
        pin(preview, inside: content)
        previewView = preview
        return preview
    }

    /// Build the PDFKit backend on first use. Continuous single-page layout scrolls a multi-page
    /// document naturally, and `PDFView` handles pinch-to-zoom itself.
    private func ensurePDFView() -> PDFView {
        if let pdfView { return pdfView }
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // The full-screen surface is deliberately black behind the page; the others follow the
        // window. Reusing this view's own backing keeps the two consistent for free.
        view.backgroundColor = backingColor
        pin(view, inside: content)
        pdfView = view
        return view
    }

    // MARK: - Layout

    private func buildSubviews() {
        content.translatesAutoresizingMaskIntoConstraints = false
        // Layer-backed so the swipe can slide it by a transform, which autolayout leaves alone.
        content.wantsLayer = true
        addSubview(content)
        guard let headerView else {
            pin(content, inside: self)
            return
        }
        addSubview(headerView)
        var constraints = [
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The safe area, not the raw top: the window runs its content under a transparent
            // title bar, and a header pinned to the bare edge draws its position readout straight
            // through the Back/Forward chevrons living up there. Caught only in a screenshot.
            headerView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        // Pinned: the header owns a strip and the preview starts below it. Floating: the preview
        // owns the whole surface and the header rides over it, so nothing shifts as it fades.
        constraints.append(
            headerStyle == .pinned
                ? content.topAnchor.constraint(equalTo: headerView.bottomAnchor)
                : content.topAnchor.constraint(equalTo: topAnchor)
        )
        NSLayoutConstraint.activate(constraints)
        if headerStyle == .floating {
            headerView.alphaValue = 0
        }
    }

    /// Pin `subview` edge to edge inside `container`, so both backends fill the surface and stack
    /// in the same place.
    private func pin(_ subview: NSView, inside container: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    // MARK: - The floating header's fade

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard headerStyle == .floating else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        revealFloatingHeader()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        revealFloatingHeader()
    }

    /// Fade the floating header in and arm its fade-out. Every movement restarts the delay, so the
    /// strip stays up while the pointer is busy and goes away once it settles.
    private func revealFloatingHeader() {
        guard let headerView, headerStyle == .floating else { return }
        headerFadeGeneration += 1
        let generation = headerFadeGeneration
        headerView.animator().alphaValue = 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.headerFadeDelay))
            guard let self, headerFadeGeneration == generation else { return }
            headerView.animator().alphaValue = 0
        }
    }
}

private extension NSView {
    /// Whether this hit belongs to a Quick View backend that should keep the mouse — the PDF
    /// document, or the surface's own header.
    func isInteractiveQuickViewBackend(pdf: NSView?, header: NSView?) -> Bool {
        if let pdf, !pdf.isHidden, isDescendant(of: pdf) { return true }
        if let header, !header.isHidden, isDescendant(of: header) { return true }
        return false
    }
}
