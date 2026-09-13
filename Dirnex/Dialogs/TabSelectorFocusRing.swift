import AppKit

/// A tab selector's focus ring drawn a few points clear of the tab it marks.
///
/// With keyboard focus on a tab view, AppKit rings the focused tab tightly around its shape, in the
/// translucent accent of `keyboardFocusIndicatorColor`. On the **selected** tab that shape is
/// already filled with the accent, so the ring sits flush against the same blue and all but
/// vanishes — measured live in Get Info, a ring plainly visible around an unselected tab reads as
/// nothing around the selected one, which is exactly where focus lands first.
///
/// The fix is geometry rather than colour: the ring is still AppKit's, drawn around a mask this
/// widens by ``gap`` on every side, so a band of the tab bar's own grey separates it from the tab.
/// `focusRingMaskBounds` is where the tab is — probed, it is the focused tab's rectangle in the tab
/// view's coordinates and moves with the arrow keys (General `(135, 5, 74, 24)`, Permissions
/// `(209, 5, 96, 24)`) — so widening that and filling it as a rounded rectangle is the whole change,
/// and unselected tabs gain the same breathing room.
///
/// Scoped like ``KeyboardReachableControls``: the browser window is left alone.
enum TabSelectorFocusRing {
    /// The clear band between a tab and its focus ring.
    static let gap: CGFloat = 3

    /// How rounded the tab itself is, before the gap is added around it.
    static let tabCornerRadius: CGFloat = 7

    static func install() {
        ObjCMethodPatch.wrapRect(#selector(getter: NSView.focusRingMaskBounds), on: NSTabView.self) { view, original in
            let tab = original()
            return ObjCMethodPatch.onMainActor(view, else: tab) { applies(to: $0) ? widened(tab) : tab }
        }
        ObjCMethodPatch.wrapVoid(#selector(NSView.drawFocusRingMask), on: NSTabView.self) { view, original in
            let drawn = ObjCMethodPatch.onMainActor(view, else: false) { view in
                guard applies(to: view) else { return false }
                let ring = view.focusRingMaskBounds
                guard !ring.isEmpty else { return false }
                let radius = tabCornerRadius + gap
                NSBezierPath(roundedRect: ring, xRadius: radius, yRadius: radius).fill()
                return true
            }
            if !drawn { original() }
        }
    }

    /// The tab's rectangle widened by ``gap``; an empty rectangle — no focused tab — stays empty.
    static func widened(_ tab: NSRect) -> NSRect {
        tab.isEmpty ? tab : tab.insetBy(dx: -gap, dy: -gap)
    }

    @MainActor
    private static func applies(to view: NSView) -> Bool {
        guard let window = view.window else { return false }
        return !(window.windowController is PaneKeyWindowController)
    }
}
