import AppKit

/// Every value of one table row, each under its column's name and wrapped to the width — the strip
/// under Quick View's table (2026-09-15).
///
/// The table cuts a value off at its column's edge, which is the only way a file whose cells run to
/// a hundred characters fits a pane at all; this is where the rest of it is read. A text view rather
/// than labels, so a value can be selected and copied, and of the preview's own text-view class so
/// the window's Esc and digit keys treat a click into it the way they treat a click into a text
/// preview (`BrowserWindowController+QuickView`).
@MainActor
final class QuickViewRecordStrip: NSView {
    private let scrollView = NSScrollView()
    private let textView = QuickViewDocumentTextView()
    private let separator = NSBox()
    private var record = NSAttributedString()
    /// The row on show, kept so a zoom can draw it again at the new size.
    private var fields: [(name: String, value: String)] = []

    /// The table's zoom, which the strip follows so the two read at one size.
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue, !fields.isEmpty else { return }
            show(fields)
        }
    }

    /// Room between the text and the strip's sides, inside the text view.
    private static let inset = NSSize(width: 10, height: 1)
    /// Blank room between the separator and the text view, which the table's drag handle lies over
    /// (`QuickViewTableView+StripHeight`). Outside the text view rather than inside it as an inset: a
    /// text view sets the I-beam across its whole frame — cursor rects, a cursor-update tracking area
    /// and its own mouse-moved handling (probed) — so a handle laid over one showed its resize
    /// cursor only along the one-point separator, however tall it was made (seen live).
    static let handleRoom: CGFloat = 11
    /// Blank room under the text view.
    private static let bottomRoom: CGFloat = 5
    /// The widest a column name may push the values to the right. A longer name sits on its own
    /// line with its value under it, rather than squeezing every value into a sliver.
    private static let nameColumnLimit: CGFloat = 180
    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize * scale, weight: .regular)
    }

    private var nameFont: NSFont {
        NSFont.systemFont(ofSize: NSFont.smallSystemFontSize * scale, weight: .medium)
    }

    init() {
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isEmpty: Bool { record.length == 0 }

    /// The text on screen, for tests.
    var text: String { textView.string }

    /// Show one row: its column names and values, in column order.
    func show(_ fields: [(name: String, value: String)]) {
        self.fields = fields
        record = attributed(fields)
        textView.textStorage?.setAttributedString(record)
        textView.scroll(.zero)
    }

    func clear() {
        fields = []
        record = NSAttributedString()
        textView.string = ""
    }

    /// The height the text needs at `width`, the blank room around it and the separator included.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat {
        guard !isEmpty else { return 0 }
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        let available = max(width - 2 * (Self.inset.width + padding), 40)
        let bounds = record.boundingRect(
            with: NSSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.height) + 2 * Self.inset.height + Self.handleRoom + Self.bottomRoom + 2
    }

    /// The blank room above and below the text is the strip's own, so it is painted here: what is
    /// behind the strip is the preview's backing, which is black in full screen.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    /// A name column as wide as the widest name that fits under the limit: the value starts at a tab
    /// stop there and its wrapped lines stay under it. A name past the limit takes a line of its own.
    private func attributed(_ fields: [(name: String, value: String)]) -> NSAttributedString {
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: nameFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let widths = fields.map { ceil(
            ($0.name as NSString).size(withAttributes: nameAttributes).width
        ) }
        let limit = Self.nameColumnLimit * scale
        let column = min(widths.filter { $0 <= limit }.max() ?? 0, limit) + 12
        let text = NSMutableAttributedString()
        for (index, field) in fields.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            paragraph.headIndent = column
            paragraph.paragraphSpacing = 3
            let name = NSMutableAttributedString(string: field.name, attributes: nameAttributes)
            let fitsBeside = widths[index] <= limit
            name.append(NSAttributedString(string: fitsBeside ? "\t" : "\n"))
            if !fitsBeside {
                paragraph.firstLineHeadIndent = 0
            }
            name.addAttribute(
                .paragraphStyle,
                value: paragraph,
                range: NSRange(location: 0, length: name.length)
            )
            text.append(name)
            let valueParagraph = fitsBeside ? paragraph : Self.indented(column)
            text.append(NSAttributedString(
                string: field.value + (index == fields.count - 1 ? "" : "\n"),
                attributes: [
                    .font: valueFont,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: valueParagraph
                ]
            ))
        }
        return text
    }

    /// The paragraph a value takes when its name sat on the line above: every line under the names.
    private static func indented(_ column: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = column
        paragraph.headIndent = column
        paragraph.paragraphSpacing = 3
        return paragraph
    }

    private func build() {
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: unbounded)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: separator.bottomAnchor,
                constant: Self.handleRoom
            ),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomRoom)
        ])
    }
}
