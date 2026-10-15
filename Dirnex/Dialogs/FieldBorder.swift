import AppKit

/// A clearer edge on every text field in the app: the system's own border, drawn again, stronger.
///
/// On macOS 26 a field's border is barely there. Probed 2026-10-09: it is a 1 pt ring just *outside*
/// the field's frame, black at 9% in Light Mode and light gray at 9% in Dark Mode, drawn by the
/// field's private `_NSCoreHostingView<AppKitTextField>`. There is no property for it. Giving a field
/// a high-contrast appearance of its own changes nothing (pixel-identical), since that view follows
/// the system's Increase Contrast setting rather than the field's appearance. So this draws the same
/// ring in the same place with `NSColor.separatorColor`, about doubling it. Oleg picked that strength
/// from three, as "a bit more noticeable".
///
/// - **It follows the system ring exactly.** The ring's centerline is 0.5 pt outside the frame with a
///   6.5 pt radius, matching the field's measured 6 pt corner (docs/NOTES.md ▸ Text fields and text
///   views). The ring is the same 9% for an editable, read-only or disabled field, and for secure and
///   token fields, so one stroke fits all of them with nothing to track. A search field's ring is a
///   capsule, so there the radius is half its height.
/// - **It is installed on `NSTextField` rather than at each site**, as ``KeyboardReachableControls``
///   is, because fields come from places nobody here builds: an `NSAlert`'s accessory, and the
///   private field behind each ``MultiLineField``. A field gets one when it joins a window, and only
///   when it is bezeled. That leaves out labels, table cells (`isBordered = false` clears the bezel
///   too, probed), the palette's borderless search, and the pane's inline rename, which draws a
///   plain border of its own. A field made bezeled only after joining a window would get none; none
///   does.
/// - The stroke is a subview at the very back, so the field's own drawing, its focus ring included,
///   stays on top of it. It takes no clicks and is no accessibility element.
enum FieldBorder {
    /// Install once, before any window is built. Safe to call again; later calls do nothing.
    static func install() {
        _ = installation
    }

    private static let installation: Void = {
        ObjCMethodPatch.wrapVoid(#selector(NSView.viewDidMoveToWindow), on: NSTextField.self) { view, original in
            original()
            ObjCMethodPatch.onMainActor(view, else: ()) { attach(to: $0) }
        }
    }()

    /// The stroke `field` was given, if any.
    @MainActor
    static func border(of field: NSView) -> FieldBorderView? {
        field.subviews.lazy.compactMap { $0 as? FieldBorderView }.first
    }

    /// Give `view` its stroke if it is a bezeled field in a window and has none yet.
    @MainActor
    static func attach(to view: NSView) {
        guard let field = view as? NSTextField,
              field.window != nil,
              field.isBezeled,
              border(of: field) == nil else { return }
        let border = FieldBorderView(frame: field.bounds.insetBy(dx: -1, dy: -1))
        border.autoresizingMask = [.width, .height]
        field.addSubview(border, positioned: .below, relativeTo: nil)
    }
}

/// The stroke ``FieldBorder`` lays over a field's own border, 1 pt outside the field's frame.
final class FieldBorderView: NSView {
    /// The ring's corner radius at its centerline: the field's 6 pt corner, 0.5 pt further out.
    static let cornerRadius: CGFloat = 6.5

    /// Clicks belong to the field.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    /// The ring's centerline.
    var path: NSBezierPath {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = superview is NSSearchField ? rect.height / 2 : Self.cornerRadius
        return NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = path
        path.lineWidth = 1
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}
