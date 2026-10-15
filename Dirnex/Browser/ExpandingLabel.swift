import AppKit

/// A single-line label whose value floats whole when the column is too narrow for it, as Finder and
/// every stock list does for a name that does not fit. Used for every file-list cell
/// (`FileCellView`). The floated panel itself is `ExpansionPanel`, put up on hover
/// (`HoverExpansion`) and for the cursor row on a held ⌘ (`CursorNamePeek`); this label's cell
/// answers where the panel goes (`expansionFrame`) and draws what is in it.
///
/// The drawing began as an override of AppKit's own expansion tooltip, which got it wrong here for a
/// reason no test can see. Measured on the live pane: the expansion was painted into a window of
/// AppKit's own making, which knows nothing about `PanelRowView`'s custom cursor fill (PLAN.md §M15
/// Slice 2) — so it drew the system's selection material while the cell handed it text in
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
    /// The floated panel's corner.
    static let cornerRadius: CGFloat = 3

    /// Air between the floated text and the panel's border, per side. The stock frame hugs the
    /// glyphs — about 3 pt from the stroke on the sides and less above and below — which is hard
    /// to read against a hairline border. The panel is sized from `expansionFrame`, so a name AppKit
    /// measures at 313 × 17 pt floats at 321 × 21 pt (measured on the live pane), the text where it
    /// was.
    static let padding = NSSize(width: 4, height: 2)

    /// The color the floated panel draws its text in — the row's *resting* color, pushed down by
    /// `FileCellView.applyStyle`. `nil` leaves whatever the cell already holds, which is right for
    /// every label that is not a file row.
    var expansionInk: NSColor?

    /// AppKit's frame, grown outward by `padding`, so the panel grows around the text and the text
    /// still lands exactly over the truncated one in the row.
    override func expansionFrame(withFrame cellFrame: NSRect, in view: NSView) -> NSRect {
        let frame = super.expansionFrame(withFrame: cellFrame, in: view)
        // An empty frame is AppKit's "it fits, show nothing". Growing that would float a panel
        // over every row.
        guard !frame.isEmpty else { return frame }
        return frame.insetBy(dx: -Self.padding.width, dy: -Self.padding.height)
    }

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
        // The text goes back into the frame AppKit measured, before `expansionFrame` padded it.
        super.draw(
            withExpansionFrame: cellFrame.insetBy(dx: Self.padding.width, dy: Self.padding.height),
            in: view
        )
        textColor = ink
    }
}
