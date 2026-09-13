import AppKit

/// The focus ring a color well does not draw for itself once Tab can reach it.
///
/// ``KeyboardReachableControls`` puts color wells on the Tab loop with System Settings ▸ Keyboard ▸
/// Keyboard navigation off, and a well that takes focus that way shows nothing. Measured live on the
/// Settings wells 2026-09-13: `becomeFirstResponder` returns `true` and Space opens the Colors panel,
/// but no ring draws, even with `setKeyboardFocusRingNeedsDisplay` and `noteFocusRingMaskChanged`
/// called on focus. The well's drawing is AppKit's own `_NSCoreHostingView<AppKitColorWell>`, so
/// whatever withholds the ring is inside it. Tabbing onto a control you cannot see is worse than not
/// reaching it, so the well is given this view the first time it takes focus.
///
/// **It keeps itself current rather than being told.** It watches its window's first responder and
/// key state, so it hides when focus moves on, when the window goes to the background and when the
/// well leaves the window — a SwiftUI tab switch removes it without a `resignFirstResponder`.
///
/// **It draws only while the system switch is off**, the one state measured without a ring. With the
/// switch on AppKit may draw its own, and two rings is the worse guess.
///
/// The shape follows the well's own capsule, `outset` points outside it in
/// `NSColor.keyboardFocusIndicatorColor`, resolved at draw time so appearance changes follow. Nothing
/// between a Settings well and its row clips that close: the grouped row leaves 10 pt around it.
@MainActor
final class ColorWellFocusRing: NSView {
    /// Whether `window` is key. A seam because a test host's windows never are.
    static var windowIsKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    /// Whether the system's Keyboard navigation switch is on. A seam for the same reason.
    static var systemDrawsRings: () -> Bool = { NSApp.isFullKeyboardAccessEnabled }

    /// How far outside the well the ring reaches, which is also its stroke width.
    static let outset: CGFloat = 3

    /// Give `well` its ring if it has none yet, and bring the ring up to date.
    static func attach(to well: NSView) {
        if let ring = ring(of: well) {
            ring.refresh()
            return
        }
        let ring = ColorWellFocusRing(frame: well.bounds.insetBy(dx: -outset, dy: -outset))
        ring.autoresizingMask = [.width, .height]
        well.addSubview(ring, positioned: .above, relativeTo: nil)
    }

    /// The ring `well` was given, if it has taken focus since it was built.
    static func ring(of well: NSView) -> ColorWellFocusRing? {
        well.subviews.lazy.compactMap { $0 as? ColorWellFocusRing }.first
    }

    private var responderObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        // Any window, filtered on arrival: the ring moves between windows with its well, and there are
        // only ever a handful of rings to wake.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateChanged),
                name: name,
                object: nil
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks belong to the well underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = nil
        guard let window else {
            isHidden = true
            return
        }
        responderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    @objc private func windowKeyStateChanged(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        refresh()
    }

    /// Show the ring exactly while the well holds focus in a key window, with the system drawing none.
    func refresh() {
        guard let window, let well = superview else {
            isHidden = true
            return
        }
        let focused = window.firstResponder === well
        let shows = focused && Self.windowIsKey(window) && !Self.systemDrawsRings()
        if shows { needsDisplay = true }
        isHidden = !shows
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: Self.outset / 2, dy: Self.outset / 2)
        let radius = min(rect.width, rect.height) / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = Self.outset
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.stroke()
    }
}
