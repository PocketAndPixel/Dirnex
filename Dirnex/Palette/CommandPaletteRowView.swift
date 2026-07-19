import AppKit
import DirnexCore

/// One result row in the command palette: the command title (with the query's matched
/// characters emphasized), its category on the left as a faint tag, and its shortcut on the
/// right. A plain `NSTableCellView` subclass so `NSTableView` can reuse it.
final class CommandPaletteRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("CommandPaletteRow")

    private let titleLabel = NSTextField(labelWithString: "")
    private let categoryLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        categoryLabel.font = .systemFont(ofSize: 11)
        categoryLabel.textColor = .tertiaryLabelColor
        categoryLabel.lineBreakMode = .byTruncatingTail
        categoryLabel.setContentHuggingPriority(.required, for: .horizontal)
        categoryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [categoryLabel, titleLabel, shortcutLabel])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        // Pin the category tag to a fixed width so titles line up across rows — wide enough
        // for the longest tag ("WORKSPACE").
        categoryLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    /// Render `match`, emphasizing the matched characters and dimming when `selected` is
    /// false so the highlighted row's text stays legible over the selection fill. `shortcut`
    /// is the command's *effective* binding (the user's rebinding or the catalog default),
    /// resolved by the palette so a rebound shortcut shows the same here as in the menu.
    func configure(with match: CommandMatch, shortcut: CommandShortcut?, selected: Bool) {
        titleLabel.attributedStringValue = Self.highlightedTitle(
            match.command.title,
            offsets: match.titleMatchOffsets,
            selected: selected
        )
        categoryLabel.stringValue = match.command.category.title.uppercased()
        shortcutLabel.stringValue = shortcut?.display ?? ""

        categoryLabel.textColor = selected ? .white.withAlphaComponent(0.7) : .tertiaryLabelColor
        shortcutLabel.textColor = selected ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
    }

    /// Build the title with the matched characters bold-emphasized. On a selected row the
    /// text is white to read over the accent fill; otherwise it uses the label color.
    private static func highlightedTitle(
        _ title: String,
        offsets: [Int],
        selected: Bool
    ) -> NSAttributedString {
        let base = selected ? NSColor.white : NSColor.labelColor
        let result = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: base
            ]
        )
        let highlightFont = NSFont.systemFont(ofSize: 13, weight: .bold)
        let characters = Array(title)
        for offset in offsets where offset >= 0 && offset < characters.count {
            result.addAttributes(
                [.font: highlightFont],
                range: NSRange(location: offset, length: 1)
            )
        }
        return result
    }
}
