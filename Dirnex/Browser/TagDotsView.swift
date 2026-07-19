import AppKit
import DirnexCore

/// The Finder-tag dots that ride at the right edge of a file's name (PLAN.md §M6 "Finder tags:
/// column…"). Lives inside `FileCellView`, right-aligned, exactly where Finder puts them.
///
/// Custom-drawn rather than text, because the content *is* the colour — which is also why this
/// doesn't borrow `FileCellView.accentColor` the way the Git letter does.
///
/// **The layout is Finder's, and it was measured rather than guessed** (a file tagged
/// `Red, Green, Blue, Yellow` was written by the system, opened in Finder, and zoomed into). Both
/// things it does are the opposite of the obvious first draft:
///
/// - **The dots run in reverse.** The **last** tag sits leftmost and fully visible; each earlier tag
///   peeks out from behind it to the right, showing only a crescent. So `[Red, Blue]` reads as a
///   whole blue dot with a red sliver on its right. It is the same precedence the core found in the
///   legacy label byte, where the *last* coloured tag wins — the newest tag is the one macOS shows.
/// - **They overlap**, so four tags cost far less room than four separate dots would.
final class TagDotsView: NSView {
    /// The row's tags, in stored order. Setting them resizes and redraws.
    var tags: [FinderTag] = [] {
        didSet {
            // Compared on name *and* colour: `FinderTag.==` is name-only by design (it is identity,
            // and macOS folds case to identify a tag), so a recolour — which the core documented
            // Finder doing on its own — would slip through the plain `!=` and leave the old dot.
            let unchanged = tags.count == oldValue.count
                && zip(tags, oldValue).allSatisfy { $0.name == $1.name && $0.color == $1.color }
            guard !unchanged else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let dotDiameter: CGFloat = 9
    /// How far each dot behind the front one peeks out. A little over half the diameter: enough to
    /// read the colour comfortably, little enough that a heavily tagged file stays a cluster rather
    /// than a row of beads pushing the filename out of its own column.
    private let dotStep: CGFloat = 5.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Its own layer, which `draw(_:)` depends on: the gap between overlapping dots is punched
        // out with `.destinationOut`, and that must erase only our own dots. Sharing a layer with
        // the row would let it erase the row's background too, punching a hole through to the window.
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The width the cluster needs, so Auto Layout gives the name exactly the room the dots don't —
    /// and **all** of it when there are none, which is the overwhelmingly common row. This is what
    /// keeps tags from costing anything at all in a folder nobody has tagged.
    override var intrinsicContentSize: NSSize {
        guard !tags.isEmpty else { return NSSize(width: 0, height: dotDiameter) }
        return NSSize(
            width: dotDiameter + CGFloat(tags.count - 1) * dotStep,
            height: dotDiameter
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !tags.isEmpty else { return }
        let y = (bounds.height - dotDiameter) / 2

        // The first tag goes rightmost and at the back; each later one steps left and is drawn over
        // the last, so the final tag ends up whole and leftmost. Drawing in this order *is* the
        // stacking — there is no z-order to set.
        for (index, tag) in tags.enumerated() {
            let rect = NSRect(
                x: bounds.maxX - dotDiameter - CGFloat(index) * dotStep,
                y: y,
                width: dotDiameter,
                height: dotDiameter
            )
            if index > 0 { punchGap(around: rect) }
            draw(tag, in: rect)
        }
    }

    /// Clear a hair around a dot before drawing it, so it reads as a separate disc from the ones
    /// behind rather than merging into them — two adjacent similar colours otherwise look like one
    /// lozenge. Finder leaves the same gap. `.destinationOut` erases this view's layer only, so what
    /// shows through is the row background, whatever it happens to be (alternating, or the cursor's
    /// blue) — which is exactly why the gap can't be a stroke in some fixed colour.
    private func punchGap(around rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        context.restoreGraphicsState()
    }

    private func draw(_ tag: FinderTag, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        circle.lineWidth = 1
        guard let fill = TagDotStyle.color(for: tag.color) else {
            // A colourless tag (`Work` with no colour) gets a hollow ring. Finder draws *nothing* for
            // one; a ring costs no room and answers "is this tagged" honestly at a glance.
            TagDotStyle.colorlessStroke.setStroke()
            circle.stroke()
            return
        }
        fill.setFill()
        circle.fill()
    }
}

/// How a tag colour is painted. The eight indices are Apple's (`FinderTagColor` in the core, which
/// picks the *index*); these are the system colours that match what Finder shows for each — the
/// same core-decides-meaning / app-decides-pixels split as `GitStatusStyle`.
enum TagDotStyle {
    /// The fill for a tag's dot, or `nil` for `.none` — which has no colour to draw and is rendered
    /// as a ring instead. System colours throughout, so the dots track the user's appearance and
    /// accessibility settings rather than freezing eight literals.
    static func color(for color: FinderTagColor) -> NSColor? {
        switch color {
        case .none: nil
        case .grey: .systemGray
        case .green: .systemGreen
        case .purple: .systemPurple
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// The ring for a colourless tag — present, but deliberately quiet: it marks the file as tagged
    /// without competing with the tags that chose a colour.
    static let colorlessStroke: NSColor = .tertiaryLabelColor

    /// A dot as a standalone image, for the tag editor's menu items and the sidebar's Tags rows.
    /// Same look as the name cell's, so a colour reads identically everywhere it appears; the
    /// sidebar asks for a larger one because its rows are taller than a menu's.
    static func menuImage(for color: FinderTagColor, diameter: CGFloat = 10) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        return NSImage(size: size, flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            circle.lineWidth = 1
            if let fill = Self.color(for: color) {
                fill.setFill()
                circle.fill()
            } else {
                Self.colorlessStroke.setStroke()
                circle.stroke()
            }
            return true
        }
    }
}
