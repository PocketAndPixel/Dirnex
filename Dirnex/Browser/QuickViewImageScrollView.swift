import AppKit
import DirnexCore

/// The scroll view a Quick View image draws in, so a photograph can be zoomed and a zoomed one
/// panned (2026-09-15).
///
/// The image used to be a bare `NSImageView` pinned to the surface with `scaleProportionallyDown`,
/// which fits a large photo and never enlarges a small one — and has nowhere to put an image larger
/// than the surface. Here the image view is the document at the image's own size in points, and the
/// scroll view's **magnification** is the zoom: measured on an 8629 × 3026 panorama, a step costs
/// 0.1–0.4 ms and draws the enlarged crop sharp, because the view redraws at the magnified scale
/// rather than stretching a bitmap of the fitted size.
///
/// Two things keep the unzoomed look exactly what it was. The document is sized in *points*
/// (`NSImage.size`, which honours the file's resolution), so a Retina screenshot still opens at its
/// natural size rather than doubled. And the starting magnification is the old rule stated as a
/// number: the fit, but never above 1.
///
/// Unlike the text, PDF and web backends, an image's zoom is an **absolute** scale rather than one
/// relative to how it opened, and ⌘0 goes back to the fit. A photograph opens at some arbitrary
/// fraction — 0.39 for that panorama — and stepping from there along `QuickViewZoom`'s ladder lands
/// on 50 %, 67 %, 100 %, so actual size is a step you can reach instead of a number you cannot.
@MainActor
final class QuickViewImageScrollView: NSScrollView {
    let imageView = NSImageView()

    /// Whether the image is at its fit, and so should go on fitting as the surface changes size —
    /// true when an image arrives and after ⌘0, false once a step or a pinch has moved it.
    private(set) var isAtStartingZoom = true

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        maxMagnification = CGFloat(QuickViewZoom.levels.last ?? 1)
        // The document is sized by frame, never by constraints. An `NSImageView` defends its image's
        // size at priority 750, and pinned by constraints a wide photo once pushed the chain outwards
        // until the *window* ran past the display (docs/NOTES.md ▸ AppKit).
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        documentView = imageView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Show `image` at its fit, centred.
    func show(_ image: NSImage?) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image?.size ?? .zero)
        isAtStartingZoom = true
        fit()
    }

    /// The current scale: 1 is the image at its own size in points.
    var zoomLevel: Double { Double(magnification) }

    /// The scale the image opened at — the fit, never above 1.
    var startingZoomLevel: Double { Double(fittedMagnification) }

    /// Scale to `level`, keeping the middle of what is on screen in the middle.
    func setZoomLevel(_ level: Double) {
        let visible = documentVisibleRect
        setMagnification(CGFloat(level), centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        isAtStartingZoom = abs(level - startingZoomLevel) < 0.001
    }

    /// Back to the fit.
    func resetZoom() {
        isAtStartingZoom = true
        fit()
    }

    /// Whether the image is wider than the surface, so a sideways two-finger scroll should pan it
    /// rather than turn to the next file.
    var pansHorizontally: Bool {
        imageView.frame.width > contentView.bounds.width + 0.5
    }

    override func layout() {
        super.layout()
        // A window resize refits an image nobody has zoomed, as the old fitted view did; a zoomed one
        // keeps the scale somebody chose.
        if isAtStartingZoom { fit() }
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        isAtStartingZoom = abs(zoomLevel - startingZoomLevel) < 0.001
    }

    private var fittedMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, min(bounds.width / size.width, bounds.height / size.height))
    }

    private func fit() {
        let start = fittedMagnification
        // A photograph far larger than the surface fits below the ladder's smallest step; the pinch
        // must be able to reach its own starting point.
        minMagnification = min(CGFloat(QuickViewZoom.levels.first ?? 1), start)
        if abs(magnification - start) > 0.0001 { magnification = start }
    }
}

/// A clip view that keeps a document smaller than itself in the middle instead of the corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}
