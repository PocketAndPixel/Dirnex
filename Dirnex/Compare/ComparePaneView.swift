import AppKit
import DirnexCore

/// One side of the compare window (PLAN.md §M31 Slice 3): the file's name and where it is, then
/// its text with line numbers beside it. The merge window's panes are the same view with no side
/// (PLAN.md §M34 Slice 3).
@MainActor
final class ComparePaneView: NSView {
    /// The side of a two-way comparison, or `nil` for a pane of the merge window, which has no
    /// Edit button.
    let side: ComparisonPaneText.Side?
    let scrollView = NSScrollView()
    let textView = CompareTextView()
    let lineNumbers: CompareLineNumbers
    private let coloring = CompareRowColoring()
    let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    /// Edit Left or Edit Right, at the end of the name's row: the file in the user's editor
    /// (PLAN.md §M33 Slice 5).
    let editButton = NSButton()
    var onEdit: (() -> Void)?
    /// The width the current text needs to show its widest row on one line.
    private var documentWidth: CGFloat = 0

    init(side: ComparisonPaneText.Side?) {
        self.side = side
        lineNumbers = CompareLineNumbers(textView: textView)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildHeader()
        buildText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Name the file over the pane, marked when its lines differ from the file as read.
    func setTitle(_ name: String, detail: String, edited: Bool = false) {
        nameLabel.stringValue = edited
            ? String(
                localized: "\(name) — Edited",
                comment: "Compare window pane header: a file with copied changes not yet saved; %@ is its name."
            )
            : name
        pathLabel.stringValue = detail
        pathLabel.toolTip = detail
        textView.setAccessibilityLabel(name)
    }

    /// "Edit Left in TextEdit", or "Edit Left" when no editor resolves.
    static func editTitle(_ side: ComparisonPaneText.Side, in editor: String? = nil) -> String {
        switch (side, editor) {
        case (.left, nil):
            String(
                localized: "Edit Left",
                comment: "Compare window button: open the left file in a text editor."
            )
        case (.right, nil):
            String(
                localized: "Edit Right",
                comment: "Compare window button: open the right file in a text editor."
            )
        case let (.left, editor?):
            String(
                localized: "Edit Left in \(editor)",
                comment: "Compare window button tooltip: open the left file in a text editor; %@ is the editor's name."
            )
        case let (.right, editor?):
            String(
                localized: "Edit Right in \(editor)",
                comment: "Compare window button tooltip: open the right file in a text editor; %@ is the editor's name."
            )
        }
    }

    @objc private func edit(_ sender: Any?) {
        onEdit?()
    }

    /// Show one column of rows: `fills` paints each row, and `endingDiffers` marks the rows whose
    /// line ending differs from the other side's.
    func show(
        _ pane: ComparisonPaneText,
        document: NSAttributedString,
        fills: [AlignedRowFill],
        endingDiffers: [Bool] = [],
        lineCount: Int
    ) {
        coloring.update(fills: fills, rowStarts: pane.rowStarts)
        textView.pane = pane
        lineNumbers.endingDiffers = endingDiffers
        lineNumbers.largestNumber = lineCount
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        documentWidth = CompareTextStyle.documentWidth(for: pane, padding: padding)
        textView.textStorage?.setAttributedString(document)
        needsLayout = true
        lineNumbers.needsDisplay = true
    }

    override func layout() {
        super.layout()
        // As wide as the widest row, and never narrower than the pane, so a row's color reaches the
        // pane's right edge.
        let width = max(documentWidth, scrollView.contentSize.width)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        }
    }

    // MARK: - Building

    private func buildHeader() {
        nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        for label in [nameLabel, pathLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            addSubview(label)
        }
        editButton.image = side.flatMap {
            NSImage(systemSymbolName: "pencil", accessibilityDescription: Self.editTitle($0))
        }
        editButton.isHidden = side == nil
        editButton.imagePosition = .imageOnly
        editButton.isBordered = false
        editButton.target = self
        editButton.action = #selector(edit(_:))
        editButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(editButton)
        NSLayoutConstraint.activate([
            editButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: editButton.leadingAnchor,
                constant: -4
            ),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
        ])
    }

    /// A read-only TextKit 2 view of a fixed width, inside a scroll view that scrolls both ways.
    private func buildText() {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = CompareTextStyle.font
        textView.defaultParagraphStyle = CompareTextStyle.paragraph
        // No horizontal inset, so a row's color starts at the pane's edge; the line fragment padding
        // keeps the text off it.
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        textView.minSize = .zero
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.textContainer?.widthTracksTextView = true
        textView.textLayoutManager?.delegate = coloring

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.findBarPosition = .aboveContent
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(lineNumbers)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            lineNumbers.topAnchor.constraint(equalTo: scrollView.topAnchor),
            lineNumbers.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            lineNumbers.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: lineNumbers.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
