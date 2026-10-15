import AppKit

/// The panel that floats a value its column cuts short, whole and in place: on hover
/// (`HoverExpansion`) and on a held ⌘ (`CursorNamePeek`). One panel for both, drawn by
/// `ExpandingLabelCell`, so the two gestures cannot drift apart in how they look.
///
/// **It replaces AppKit's own expansion tooltip** (`allowsExpansionToolTips`), which no file cell
/// turns on any more. Measured 2026-10-15 on the live pane: AppKit floats the value in an
/// `NSToolTipPanel` that is **opaque**, with a square white backing behind the cell's rounded panel,
/// and draws it inside an `NSVisualEffectView`, whose vibrancy turns the ink gray. The same cell
/// drawing therefore came out square-cornered and pale on hover and rounded and dark in a window of
/// our own, on the same row. Neither difference is reachable without reaching into AppKit's private
/// window from inside a draw call.
///
/// The panel is a borderless child window at the frame AppKit's took (the logged frames matched to
/// the point), with AppKit's shadow, and it ignores the mouse, so a click on it lands on the row
/// underneath as it did on AppKit's. It draws a copy of the value rather than the row's own cell,
/// because that cell goes back to the table's reuse pool and may be showing another name by the next
/// redraw.
@MainActor
enum ExpansionPanel {
    /// Which gesture put the panel up, so that each one takes down only its own.
    enum Owner {
        case hover
        case commandHold
    }

    /// A label's value and where it sits. Compared instead of the label itself, because a reload can
    /// hand the row a different cell view showing the same name in the same place, and the panel over
    /// it is still right.
    struct Key: Equatable {
        let text: String
        let window: ObjectIdentifier
        let frame: NSRect
    }

    private static var panel: NSPanel?
    private static var shownKey: Key?

    /// The gesture whose panel is up, or `nil` when none is.
    private(set) static var owner: Owner?

    /// The panel on screen now, if any. For tests.
    static var shownPanel: NSPanel? { panel }

    /// `label`'s key, or `nil` when it is in no window.
    static func key(for label: NSTextField) -> Key? {
        guard let window = label.window else { return nil }
        return Key(
            text: label.stringValue,
            window: ObjectIdentifier(window),
            frame: label.convert(label.bounds, to: nil)
        )
    }

    /// Whether the panel up now is the one for `label`.
    static func isShowing(_ label: NSTextField) -> Bool {
        shownKey != nil && key(for: label) == shownKey
    }

    /// Float `label`'s value over it, replacing any panel already up, if its column truncates it.
    /// `true` when a panel went up; a value that fits leaves whatever is up alone.
    @discardableResult
    static func show(over label: NSTextField, for owner: Owner) -> Bool {
        guard let window = label.window, let frame = screenFrame(for: label) else { return false }
        hide()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.appearance = window.effectiveAppearance
        panel.contentView = ExpansionPanelView(
            cell: snapshot(of: label),
            frame: NSRect(origin: .zero, size: frame.size)
        )
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        self.owner = owner
        shownKey = key(for: label)
        return true
    }

    /// Take the panel away, whoever put it up.
    static func hide() {
        owner = nil
        shownKey = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Take the panel away if `owner` put it up, and leave another gesture's alone.
    static func hide(ifShownBy owner: Owner) {
        guard self.owner == owner else { return }
        hide()
    }

    /// Where on screen the panel goes: the frame `label`'s cell answers for its expansion, so the
    /// value lands over the truncated one exactly as AppKit's panel did. `nil` when the value fits.
    /// Rounded out to whole points, as AppKit's own window was.
    static func screenFrame(for label: NSTextField) -> NSRect? {
        guard let cell = label.cell, let window = label.window else { return nil }
        let frame = cell.expansionFrame(withFrame: label.bounds, in: label)
        guard !frame.isEmpty else { return nil }
        return window.convertToScreen(label.convert(frame, to: nil)).integral
    }

    /// A cell drawing what `label` shows, in the ink its own cell would float.
    static func snapshot(of label: NSTextField) -> ExpandingLabelCell {
        let cell = ExpandingLabelCell(textCell: label.stringValue)
        cell.font = label.font
        cell.alignment = label.alignment
        cell.lineBreakMode = label.lineBreakMode
        cell.usesSingleLineMode = true
        cell.textColor = label.textColor
        cell.expansionInk = (label.cell as? ExpandingLabelCell)?.expansionInk
        return cell
    }
}

/// The panel's content: the value drawn by its own `ExpandingLabelCell`, fill and border included.
private final class ExpansionPanelView: NSView {
    private let cell: ExpandingLabelCell

    init(cell: ExpandingLabelCell, frame: NSRect) {
        self.cell = cell
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Flipped like the row's own label, so the cell lays the line out from the top of its frame as the
    /// label does. Unflipped it is laid out from the bottom, which put the text a point low while the
    /// frame was AppKit's, a point taller than the label (measured by ink at 2× against the row: 1 pt
    /// at 11 and 13 pt, 1.5 at 18). `ExpandingLabelCell.expansionFrame` now trims that point too, and
    /// either fix alone aligns the text; this one keeps it aligned whatever height the frame has.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        cell.draw(withExpansionFrame: bounds, in: self)
    }
}
