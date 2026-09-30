import AppKit

/// A single-line label that floats its whole value when the column is too narrow for it —
/// AppKit's own expansion tooltip, which is what Finder and every stock list does for a name that
/// does not fit. Used for every file-list cell (`FileCellView`); the caller opts in by setting
/// `allowsExpansionToolTips`.
///
/// It exists only to own the *drawing* of that expansion, which the stock one gets wrong here for a
/// reason no test can see. Measured on the live pane: the expansion is painted into a window of
/// AppKit's own making, which knows nothing about `PanelRowView`'s custom cursor fill (PLAN.md §M15
/// Slice 2) — so it draws the system's selection material while the cell hands it text in
/// `PanelPalette.cursorForeground`, a color *derived from the user's* fill. With an untouched
/// palette the two agree by luck (white ink, blue material). With a pale cursor color the derived
/// ink is **black** and the material is still dark: black on dark, on the one row the user is
/// pointing at. The row underneath is meanwhile perfectly legible, which is what makes it read as a
/// rendering glitch rather than as a color bug.
///
/// So the panel is ours: an opaque fill in the pane's own text background, carrying the color the
/// row's text would have had if it were *not* the cursor — pushed down by `FileCellView.applyStyle`,
/// which is the only place that knows. It has to be pushed, and that is measured rather than
/// assumed: at expansion-draw time this cell reports `backgroundStyle == .normal` **on the cursor
/// row**, holding the palette-derived ink, so there is no state here to branch on. (The neighboring
/// fact in docs/NOTES.md ▸ AppKit — a cell cannot tell a selected-but-unfocused row from an ordinary
/// one — turns out to cover the emphasized row too, at this hook.)
///
/// Everything the resting color can be is already authored against `.textBackgroundColor` — a
/// file-type rule's color, the mark's red, `.labelColor` — which is precisely what the panel is
/// filled with, so a marked or type-colored name keeps its color in the panel and stays legible.
final class ExpandingLabel: NSTextField {
    override static var cellClass: AnyClass? {
        get { ExpandingLabelCell.self }
        set { super.cellClass = newValue }
    }
}

/// The cell behind `ExpandingLabel`. Split out because the drawing hook is `NSCell`'s, not the
/// field's — and reached through `cellClass`, which `NSTextField.labelWithString(_:)` honors on a
/// subclass (probed: the factory hands back an `ExpandingLabelCell`).
final class ExpandingLabelCell: NSTextFieldCell {
    /// Matches the corner AppKit's own expansion panel draws.
    static let cornerRadius: CGFloat = 3

    /// The color the floated panel draws its text in — the row's *resting* color, pushed down by
    /// `FileCellView.applyStyle`. `nil` leaves whatever the cell already holds, which is right for
    /// every label that is not a file row.
    var expansionInk: NSColor?

    override func draw(withExpansionFrame cellFrame: NSRect, in view: NSView) {
        // Paint the backing before anything else. The stock drawing is *glyphs only* — probed, the
        // default `draw(withExpansionFrame:in:)` leaves the panel fully transparent (corner alpha 0)
        // and lets the window behind supply the fill — so filling here is what takes the color out
        // of AppKit's hands rather than layering over it.
        let panel = NSBezierPath(
            roundedRect: cellFrame.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        NSColor.textBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()

        let ink = textColor
        if let expansionInk { textColor = expansionInk }
        super.draw(withExpansionFrame: cellFrame, in: view)
        textColor = ink
    }
}
