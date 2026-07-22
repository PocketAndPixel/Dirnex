import AppKit
import PDFKit
import Quartz

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
    private let content = NSView()

    private var previewView: QLPreviewView?
    private var pdfView: PDFView?
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Backends

    /// Show `url` in the Quick Look backend, standing down the PDF one.
    private func showQuickLook(_ url: URL?) {
        guard let preview = ensureQuickLookPreview() else { return }
        pdfView?.isHidden = true
        pdfView?.document = nil
        preview.isHidden = false
        preview.previewItem = url as NSURL?
    }

    /// Show `url` in the PDFKit backend, standing down the Quick Look one. `autoScales` refits the
    /// page to the surface for each new document; the user can then pinch to zoom in or out.
    private func showPDF(_ url: URL) {
        let pdfView = ensurePDFView()
        previewView?.isHidden = true
        previewView?.previewItem = nil
        pdfView.isHidden = false
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
    }

    /// Whether `url` is a PDF, so it routes to `PDFView`. Prefers the file's real content type
    /// (catches an odd extension) and falls back to the extension when that can't be read.
    private static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
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
