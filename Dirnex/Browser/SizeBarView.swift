import AppKit
import DirnexCore

/// One row's ncdu-style bar, plus its share of the folder (PLAN.md §M6 "toggle panel to ncdu-style
/// bars"). Lives in the contextual bar column that `PanelViewController+SizeViz` installs.
///
/// **Bar *and* percentage, because measurement says the bar alone cannot carry it.** ncdu's manual
/// splits the two — *"Percentage is relative to the size of the current directory, graph is relative
/// to the largest item"* — and pass 9 built both denominators into `SizeBar` for exactly that. Pass
/// 10 measured why it matters: the dynamic range in a real `~` is ~10⁶, so **86 of its 93 rows** land
/// under half a point of bar at any width a file pane can spare. They are floored to a visible stub
/// (`SizeBar.inkWidth`), which honestly reads "this is noise" — and the number beside it is what
/// distinguishes 0.9 % from 0.0001 % once the bar has given up. Drawing one without the other would
/// leave the whole tail of every big folder unreadable.
final class SizeBarView: NSView {
    /// The row's bar, or `nil` while its total is still unknown — a directory the scan has not
    /// reached yet. The distinction is the core's (`SizeVisualization.bar(for:)` answers `nil`
    /// rather than zero) and it is preserved all the way to the pixels: **unknown draws nothing at
    /// all**, where a known-empty folder draws an empty track. A 0 %-looking bar on an unwalked
    /// 40 GB folder would be a lie, and the two are indistinguishable if collapsed.
    var bar: SizeBar? {
        didSet {
            guard bar != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Whether this row is the cursor, so the bar can pick a fill that survives the emphasized blue
    /// behind it. Pushed down by `SizeBarCellView` — `backgroundStyle` is `NSTableCellView`'s
    /// property, not `NSView`'s, so this view cannot observe it directly.
    var isEmphasized = false {
        didSet {
            guard isEmphasized != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The bar's own minimum, in points, for any row holding bytes. ~1.5 pt is 3 device pixels at
    /// 2x — unmistakably present, still obviously nothing. See `SizeBar.inkWidth`.
    private let minimumInk: CGFloat = 1.5
    private let barHeight: CGFloat = 8
    /// Room for "100.0%" at the small system font, measured once rather than guessed at.
    private static let labelWidth: CGFloat = {
        let widest = "100.0%" as NSString
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        return ceil(widest.size(withAttributes: [.font: font]).width) + 4
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Unknown: draw *nothing*. Not an empty track — a track would claim the row was measured and
        // found to be nothing, which is the one thing we do not know about it yet.
        guard let bar else { return }

        let trackRect = NSRect(
            x: bounds.minX,
            y: (bounds.height - barHeight) / 2,
            width: max(0, bounds.width - Self.labelWidth),
            height: barHeight
        )
        drawTrack(in: trackRect)
        drawFill(bar, in: trackRect)
        drawShare(bar)
    }

    /// The empty track behind the bar — what makes a floored stub read as "1 % of the biggest
    /// sibling" instead of "a stray mark". Without it the tail rows are ambiguous smudges.
    ///
    /// **The track must read as a recess, never as ink, and the cursor row is where that is hard to
    /// get right.** Off the cursor the two are different colours and the distinction is free. On it,
    /// both are `alternateSelectedControlTextColor` — the only fill that survives the emphasized blue
    /// — separated by alpha alone, and the track has the whole column's width to shout with where the
    /// ink may have a point and a half. At 0.25 an *empty* track therefore read as a *full* bar:
    /// caught live on a wholly-ignored `build/` showing "Zero KB · 0.0 %" beside what looked like the
    /// heaviest row in the folder. `.gitignore`-aware sizing is what made that common — whole folders
    /// legitimately total zero now — but the inversion was always there for any empty directory the
    /// cursor happened to sit on.
    private func drawTrack(in rect: NSRect) {
        guard rect.width > 0 else { return }
        (isEmphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.12)
            : NSColor.quaternaryLabelColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    private func drawFill(_ bar: SizeBar, in track: NSRect) {
        // The floor is the core's rule, applied to the width this pane actually has — the pane is
        // resizable, so it cannot be precomputed.
        let ink = bar.inkWidth(in: Double(track.width), minimum: Double(minimumInk))
        guard ink > 0 else { return }
        barColor.setFill()
        NSBezierPath(
            roundedRect: NSRect(
                x: track.minX,
                y: track.minY,
                width: CGFloat(ink),
                height: track.height
            ),
            xRadius: 2,
            yRadius: 2
        ).fill()
    }

    /// The bar's fill. On the cursor row the emphasized background is already blue, so a blue bar
    /// would vanish into it — the same contrast problem `FileCellView.applyStyle` solves for text,
    /// solved the same way.
    private var barColor: NSColor {
        isEmphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }

    /// ncdu's percentage, right-aligned past the track. Drawn rather than hosted in an `NSTextField`
    /// because this view is already custom-drawn and a label would double the view count on every row
    /// of a hundred-thousand-row directory for one short string.
    private func drawShare(_ bar: SizeBar) {
        let text = String(format: "%.1f%%", bar.share * 100) as NSString
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let color: NSColor = isEmphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        let size = text.size(withAttributes: [.font: font, .foregroundColor: color])
        text.draw(
            at: NSPoint(x: bounds.maxX - size.width, y: (bounds.height - size.height) / 2),
            withAttributes: [.font: font, .foregroundColor: color]
        )
    }
}

/// The bar column's cell: nothing but a `SizeBarView` filling it.
///
/// A cell of its own rather than a `FileCellView` variant, because `FileCellView` is built around an
/// `NSTextField` (mark styling, the hidden-file dim, the F2 rename editor) and this column has no
/// text field at all. It still honours the two states a row can be in — `marked` and `dimmed` —
/// because a bar that ignored them would be the one cell in the row that did.
final class SizeBarCellView: NSTableCellView {
    let barView = SizeBarView()

    /// Faded for a hidden (dot) entry, exactly as `FileCellView` fades icon and text, so the row
    /// dims as one thing. Hidden rows are half of what a size-viz pane shows in `~` — measured, 68
    /// of its 93 rows are dotfiles — so this is the common case, not an edge.
    var dimmed = false {
        didSet { alphaValue = dimmed ? 0.5 : 1 }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        barView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(barView)
        NSLayoutConstraint.activate([
            barView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            barView.topAnchor.constraint(equalTo: topAnchor),
            barView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `NSTableView` sets this on the cell as the row's selection changes; the bar needs it to pick
    /// a fill that survives the cursor's blue, so pass it down.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { barView.isEmphasized = backgroundStyle == .emphasized }
    }
}
