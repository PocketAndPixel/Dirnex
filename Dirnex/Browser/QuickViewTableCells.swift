import AppKit
import DirnexCore

/// One cell: a single-line label, centered vertically, cut off with an ellipsis, and floating its
/// whole value on hover when it was cut.
@MainActor
final class QuickViewTableCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QuickViewTableCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A line break inside a quoted value would push the rest of it below the row, so a cell draws
    /// one as a space; the strip shows the value as written.
    ///
    /// Given the query a filter kept the row by, the cell marks where it lies in find yellow
    /// (2026-09-15): within `searched`, the part of `value` the filter read, which leaves out the
    /// quotes the JSON tree draws around a string, and within the first `markedLength` characters of
    /// it, past which a cell is cut off anyway. The rest of the text carries no color of its own, so
    /// the label's color applies to it, and so does the white a selected row turns that color — which
    /// a `labelColor` attribute would not (measured: it stays dark on a selected row).
    func show(
        _ value: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        marking query: FilterQuery? = nil,
        within searched: Range<String.Index>? = nil
    ) {
        label.font = font
        label.textColor = color
        label.alignment = alignment
        let line = Self.line(of: value, marking: query, within: searched)
        guard !line.marks.isEmpty else {
            label.stringValue = line.text
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(
            string: line.text,
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        for mark in line.marks {
            text.addAttributes(Self.markAttributes, range: mark)
        }
        label.attributedStringValue = text
    }

    /// How a match is drawn: the system's find highlight, with black text on it whatever the row's.
    static let markAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: NSColor.findHighlightColor,
        .foregroundColor: NSColor.black
    ]

    /// The most of a value, in characters, a cell looks for matches in.
    static let markedLength = 1000

    /// `value` on one line, each run of line breaks drawn as one space, and where `query` lies in that
    /// line as an attributed string counts it.
    static func line(
        of value: String,
        marking query: FilterQuery?,
        within searched: Range<String.Index>?
    ) -> (text: String, marks: [NSRange]) {
        let lines = value.contains(where: \.isNewline)
            ? value.split(whereSeparator: \.isNewline)
            : [value[...]]
        let text = lines.joined(separator: " ")
        guard let query, !query.isEmpty else { return (text, []) }
        let searched = searched ?? value.startIndex..<value.endIndex
        let limit = value.index(
            searched.lowerBound,
            offsetBy: markedLength,
            limitedBy: searched.upperBound
        ) ?? searched.upperBound
        var marks: [NSRange] = []
        // Where each line starts in `text`, in the UTF-16 units an attributed string counts.
        var lineStart = 0
        for line in lines {
            let lower = max(line.startIndex, searched.lowerBound)
            let upper = min(line.endIndex, limit)
            if lower < upper {
                let part = String(value[lower..<upper])
                let partStart = lineStart + value.utf16.distance(from: line.startIndex, to: lower)
                for occurrence in query.occurrences(in: part) {
                    marks.append(NSRange(
                        location: partStart
                            + part.utf16.distance(from: part.startIndex, to: occurrence.lowerBound),
                        length: part.utf16.distance(
                            from: occurrence.lowerBound,
                            to: occurrence.upperBound
                        )
                    ))
                }
            }
            lineStart += line.utf16.count + 1
        }
        return (text, marks)
    }
}

/// The table itself, which puts the selected rows on the pasteboard as tab-separated text — what a
/// spreadsheet reads back into cells.
@MainActor
final class QuickViewDataTableView: NSTableView, NSMenuItemValidation {
    var copiedText: ((IndexSet) -> String?)?
    /// Where ⌘C writes. The general pasteboard, except in a test, which must not overwrite the
    /// clipboard of whoever is running it.
    var pasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        guard let text = copiedText?(selectedRowIndexes), !text.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: .tabularText)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return !selectedRowIndexes.isEmpty
    }
}
