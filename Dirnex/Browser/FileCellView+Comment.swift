import AppKit

/// A row's comment, drawn in the name label after the name (PLAN.md §M40 Slice 8).
///
/// An SMB server's list carries a comment for each share (`NetCommentStr`, ``FileEntry/comment``).
/// It was a column of its own at first, which hid Size and Date on a flat list and sat between Name
/// and them in a tree, so the tab's columns changed shape with the listing. In the name label it needs
/// no column: the name comes first, the comment after it in a quieter ink, and the label's tail
/// truncation shortens the comment before the name.
///
/// It lives in the label's own text rather than in a label beside it because the name cell's layout
/// is already a tight weave of the name and its trailing badges (`installBadges(besides:)`), and a
/// second label would cost every row a gap whether or not it has a comment. The comment's run is
/// marked with an attribute of its own, so a restyle finds where the name ends without keeping a
/// copy of it.
extension FileCellView {
    /// Marks the comment's run inside the label's text.
    private static let commentRun = NSAttributedString.Key("app.dirnex.fileCell.comment")

    /// Between a name and its comment: an em space, which reads as a gap rather than a word space.
    static let commentGap = "\u{2003}"

    /// Draw `comment` after the name, or take a comment drawn earlier away. Run by `applyStyle`, after
    /// it has set the name's font and ink, so the comment follows the cursor, the mark and the
    /// appearance with it. A rename field keeps the plain name.
    func applyComment() {
        guard let textField, !isEditingName else { return }
        let shown = textField.attributedStringValue
        var nameEnd = shown.length
        shown.enumerateAttribute(
            Self.commentRun,
            in: NSRange(location: 0, length: shown.length)
        ) { value, range, stop in
            guard value != nil else { return }
            nameEnd = range.location
            stop.pointee = true
        }
        let name = (shown.string as NSString).substring(to: nameEnd)
        guard let comment, !comment.isEmpty else {
            if nameEnd < shown.length { textField.stringValue = name }
            return
        }
        let font = textField.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = textField.alignment
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: font,
            .foregroundColor: textField.textColor ?? .labelColor,
            .paragraphStyle: paragraph
        ])
        text.append(NSAttributedString(string: Self.commentGap + comment, attributes: [
            // The name's size without its weight: a marked share's name is bold, its comment is not.
            .font: NSFont.systemFont(ofSize: font.pointSize),
            .foregroundColor: commentInk,
            .paragraphStyle: paragraph,
            Self.commentRun: true
        ]))
        textField.attributedStringValue = text
    }

    /// The comment's ink: the secondary label color at rest, and on the cursor's fill the ink derived
    /// from it, softened as the secondary color softens the label's (`PanelPalette.cursorForeground`).
    var commentInk: NSColor {
        backgroundStyle == .emphasized
            ? palette.cursorForeground.withAlphaComponent(0.7)
            : .secondaryLabelColor
    }
}
