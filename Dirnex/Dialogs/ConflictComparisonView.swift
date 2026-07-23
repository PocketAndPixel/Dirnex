import AppKit
import DirnexCore

/// The accessory view inside `ConflictDialog`: the incoming ("New") and existing items shown
/// as two cards — thumbnail, name, size/kind, modification date — with the newer item's date
/// tinted so the user can decide at a glance (PLAN.md §M2 "size/date, image thumbnails").
final class ConflictComparisonView: NSView {
    init(context: ConflictContext, sourceThumbnail: NSImage, existingThumbnail: NSImage) {
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 176))

        let sourceNewer = context.source.modificationDate > context.existing.modificationDate
        let existingNewer = context.existing.modificationDate > context.source.modificationDate

        let source = Self.card(
            title: context.kind == .copy
                ? String(localized: "New (copying in)")
                : String(localized: "New (moving in)"),
            entry: context.source,
            thumbnail: sourceThumbnail,
            dateIsNewer: sourceNewer
        )
        let existing = Self.card(
            title: String(localized: "Already here"),
            entry: context.existing,
            thumbnail: existingThumbnail,
            dateIsNewer: existingNewer
        )

        let row = NSStackView(views: [source, arrow(), existing])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // The two cards share the leftover width equally, the arrow taking its own.
            source.widthAnchor.constraint(equalTo: existing.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Building blocks

    /// One item's card: header, thumbnail, name, a size-or-"Folder" line, and the modified
    /// date (tinted and flagged when this side is the newer of the two).
    private static func card(
        title: String,
        entry: FileEntry,
        thumbnail: NSImage,
        dateIsNewer: Bool
    ) -> NSView {
        let header = label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)

        let image = NSImageView()
        image.image = thumbnail
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 64),
            image.heightAnchor.constraint(equalToConstant: 64)
        ])

        let name = label(entry.name, size: 12, weight: .medium, color: .labelColor)
        name.lineBreakMode = .byTruncatingMiddle
        name.maximumNumberOfLines = 2
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detail = entry.isDirectoryLike
            ? String(localized: "Folder")
            : FileFormatting.byteString(entry.byteSize)
        let size = label(detail, size: 11, weight: .regular, color: .secondaryLabelColor)

        let dateText = FileFormatting.dateString(for: entry)
        let date = label(
            dateIsNewer ? String(localized: "\(dateText) · newer") : dateText,
            size: 11,
            weight: dateIsNewer ? .semibold : .regular,
            color: dateIsNewer ? .controlAccentColor : .secondaryLabelColor
        )

        let stack = NSStackView(views: [header, image, name, size, date])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func arrow() -> NSView {
        let arrow = ConflictComparisonView.label(
            "→",
            size: 15,
            weight: .regular,
            color: .tertiaryLabelColor
        )
        arrow.setContentHuggingPriority(.required, for: .horizontal)
        // Nudge the arrow down to sit beside the thumbnails rather than the headers.
        let container = NSStackView(views: [arrow])
        container.orientation = .vertical
        container.alignment = .centerX
        container.edgeInsets = NSEdgeInsets(top: 34, left: 0, bottom: 0, right: 0)
        return container
    }

    private static func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        return field
    }
}
