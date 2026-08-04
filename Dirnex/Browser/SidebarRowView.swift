import AppKit

/// A sidebar row, so its selection reads in the user's own cursor colour rather than the system
/// accent (PLAN.md §M15 Slice 2 — the colour the file panes' cursor already draws in).
///
/// The pane's `PanelRowView` fills a plain rectangle, because that is exactly what AppKit draws
/// there. A source list does not: it draws a **pill**, and the shape is the sidebar's whole visual
/// identity, so it has to be reproduced rather than replaced. Probed rather than eyeballed, by
/// letting `super` draw into a bitmap and measuring the ink — constant across widths (180/257/400 pt),
/// row heights (24/32 pt) and both appearances:
///
/// - inset **10 pt** on each side, and the **full row height**, top and bottom;
/// - a corner radius of **8 pt**, fitted against AppKit's own edge coverage per scanline. A circular
///   8 pt arc tracks the real curve to within half a pixel of coverage — closer than r=6, 7, 8.5 or
///   9, and closer than tinting `super`'s own output through a transparency layer, which was also
///   measured and came out half a point wide on each side.
///
/// **Only the emphasized half is filled**, for the same reason `PanelRowView` gives: AppKit's
/// unemphasized selection is a pure grey that says "the focus moved", and flattening the two makes
/// every pane and the sidebar read as permanently unfocused. What the unemphasized state *does* take
/// from the palette is its content colour — a selected-but-unfocused source-list row draws its label
/// and glyph in the accent, and that is the second place the cursor colour belongs (see
/// `SidebarCellView.selectionForeground`).
final class SidebarRowView: NSTableRowView {
    /// The cursor colour, or `nil` to let AppKit draw and tint its own selection.
    var cursorColor: NSColor? {
        didSet {
            guard cursorColor != oldValue else { return }
            needsDisplay = true
            applySelectionForeground()
        }
    }

    /// The inset and radius measured off AppKit's own pill; see the type's note.
    private static let pillInset: CGFloat = 10
    private static let pillRadius: CGFloat = 8

    override var isSelected: Bool {
        didSet { applySelectionForeground() }
    }

    override var isEmphasized: Bool {
        didSet { applySelectionForeground() }
    }

    /// The cell view arrives *after* the controller has handed this row its colour, so the push has
    /// to happen here as well as in the setters above.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        applySelectionForeground()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard let cursorColor, isEmphasized else {
            super.drawSelection(in: dirtyRect)
            return
        }
        cursorColor.setFill()
        // Derived from `bounds`, never from `dirtyRect`: `clipsToBounds` is `false` by default and a
        // `dirtyRect` can be larger than the view, so a fill measured from it paints over the view's
        // siblings (NOTES.md ▸ AppKit). A path inset inside `bounds` cannot.
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: Self.pillInset, dy: 0),
            xRadius: Self.pillRadius,
            yRadius: Self.pillRadius
        ).fill()
    }

    /// Hand each cell the colour its label and glyph should draw in: the derived foreground on top
    /// of the filled pill, the cursor colour itself on the unfocused row AppKit would have tinted
    /// with the accent, and `nil` — AppKit's own — everywhere else.
    private func applySelectionForeground() {
        var foreground: NSColor?
        if let cursorColor, isSelected {
            foreground = isEmphasized ? PanelPalette.foreground(on: cursorColor) : cursorColor
        }
        for case let cell as SidebarCellView in subviews {
            cell.selectionForeground = foreground
        }
    }
}
