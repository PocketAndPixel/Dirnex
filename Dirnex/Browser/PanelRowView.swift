import AppKit

/// A file pane's row, so the cursor's background can be a colour the user chose
/// (PLAN.md §M15 Slice 2).
///
/// AppKit draws the emphasized selection itself and exposes no colour to set, so the only way to own
/// it is to draw it. **Installed unconditionally, not only when a custom colour is set** — probed
/// rather than assumed: when the delegate declines to supply a row view, `NSTableView` makes a plain
/// `NSTableRowView`, in every one of its five styles, so a subclass that hands the call to `super`
/// is byte-for-byte the shipped drawing. Switching classes as the preference changes would leave a
/// reuse pool of the other kind to reason about; deferring leaves nothing to get wrong.
final class PanelRowView: NSTableRowView {
    /// The cursor colour, or `nil` to let AppKit draw its own selection.
    var cursorColor: NSColor? {
        didSet {
            guard cursorColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// **Only the emphasized half is ours.** Measured in both appearances, AppKit's *unemphasized*
    /// selection is a pure grey — `#DCDCDC` light, `#464646` dark, zero saturation in each — so it
    /// discards the accent's hue on purpose. That grey is the platform saying "the focus moved"
    /// (NOTES.md ▸ AppKit), and it is not even a fainter version of the emphasized fill to imitate:
    /// in dark mode it is *darker* than the emphasized one (L=0.0612 against 0.1175), not lighter.
    /// So there is nothing here to derive. Hand the inactive pane back to AppKit and both panes keep
    /// exactly the signal they carry today — which is the point, since flattening the two makes both
    /// cursors look identical and the whole window read as permanently unfocused.
    override func drawSelection(in dirtyRect: NSRect) {
        guard let cursorColor, isEmphasized else {
            super.drawSelection(in: dirtyRect)
            return
        }
        cursorColor.setFill()
        // Intersected with `bounds`, never the bare `dirtyRect`: `clipsToBounds` is `false` by
        // default and a `dirtyRect` can be larger than the view, so filling it paints over the
        // view's siblings — NOTES.md ▸ AppKit records the Quick View overlay blacking out the
        // sidebar for exactly this.
        dirtyRect.intersection(bounds).fill()
    }
}
