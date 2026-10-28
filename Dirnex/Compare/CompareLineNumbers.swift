import AppKit
import DirnexCore

/// The line numbers beside a compare pane (PLAN.md §M31 Slice 3): each row's line in its own file,
/// nothing beside a gap, and `↵` beside a line whose ending differs from the other side's.
///
/// The ending is the one difference no character in the row can show: under the default options a
/// CRLF line against an LF line is a changed row with nothing marked inside it, so the mark has to be
/// somewhere else, and the gutter is beside the row it belongs to.
///
/// **A view beside the scroll view, not an `NSRulerView` in it.** Measured 2026-10-22 in the running
/// app: with the ruler installed, the clip view's frame still started at x = 0 under the 45-point
/// ruler, so the first five columns of every line were hidden behind it. Beside the scroll view the
/// gutter cannot overlap the text, and it redraws whenever the panes scroll (`CompareScrollSync`).
@MainActor
final class CompareLineNumbers: NSView {
    weak var textView: CompareTextView?
    /// Which rows' endings differ, by row.
    var endingDiffers: [Bool] = []
    /// The largest line number, which sets the gutter's width.
    var largestNumber = 1 {
        didSet { widthConstraint.constant = Self.width(forLargest: largestNumber) }
    }

    private lazy var widthConstraint = widthAnchor.constraint(
        equalToConstant: Self.width(forLargest: 1)
    )

    private static let digitFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )
    private static let padding: CGFloat = 6
    private static let markWidth: CGFloat = 12

    init(textView: CompareTextView) {
        self.textView = textView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    static func width(forLargest number: Int) -> CGFloat {
        let digits = String(max(number, 1)).count
        let width = ("0" as NSString).size(withAttributes: [.font: digitFont]).width
        return ceil(CGFloat(max(digits, 3)) * width + 2 * padding + markWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        guard let textView, let pane = textView.pane else { return }
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.digitFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.digitFont,
            .foregroundColor: NSColor.controlAccentColor
        ]
        let numberRight = bounds.maxX - Self.padding - Self.markWidth
        let lineHeight = CompareTextStyle.lineHeight
        textView.forEachVisibleRow { row, top in
            let y = convert(NSPoint(x: 0, y: top), from: textView).y
            if let line = pane.lineIndex(ofRow: row) {
                let number = String(line + 1) as NSString
                let size = number.size(withAttributes: numberAttributes)
                number.draw(
                    at: NSPoint(x: numberRight - size.width, y: y + (lineHeight - size.height) / 2),
                    withAttributes: numberAttributes
                )
            }
            if endingDiffers.indices.contains(row), endingDiffers[row] {
                let mark = "↵" as NSString
                let size = mark.size(withAttributes: markAttributes)
                mark.draw(
                    at: NSPoint(x: numberRight + 3, y: y + (lineHeight - size.height) / 2),
                    withAttributes: markAttributes
                )
            }
        }
    }
}
