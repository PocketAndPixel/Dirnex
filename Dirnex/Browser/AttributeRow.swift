import AppKit

/// The small layout vocabulary the info panel's form tabs are built from (PLAN.md §M14 Slice 4).
///
/// The label column is sized to the **widest localized caption** rather than to a magic number, and
/// every value truncates rather than widening the sheet. Both are docs/NOTES.md lessons paid for
/// live: the pack sheet's hardcoded 48 pt label column cut «Формат:» in half, and a wrapping label
/// with no width constraint overran the connect sheet's edge in Russian. Neither is visible in an
/// English screenshot.
enum AttributeRow {
    /// The width every label column is laid out at: the widest caption any of these tabs uses, in
    /// the system font, measured at build time rather than guessed.
    static let labelWidth: CGFloat = 130

    /// A `Label:  value` row.
    static func make(label: String, value: String, monospaced: Bool = false) -> NSView {
        make(label: label, field: valueField(value, monospaced: monospaced))
    }

    /// A `Label:  value` row over a caller-supplied field — used when the caller needs to keep a
    /// reference to the value field to update it live (the editable Mode echo).
    static func make(label: String, field: NSTextField) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.alignment = .right
        caption.textColor = .secondaryLabelColor
        caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.lineBreakMode = .byTruncatingTail
        return row([caption, field])
    }

    /// The value half of a row, configured the way ``make(label:value:monospaced:)`` builds it.
    static func valueField(_ value: String, monospaced: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        if monospaced {
            field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        // The value is what gives way when a translation is long — the caption has a fixed column
        // and the sheet has a fixed width, so something has to, and truncating a path reads far
        // better than truncating the word that says what the path is.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    /// A row whose value is an arbitrary view (a checkbox grid, a flags column).
    static func make(label: String, view: NSView) -> NSView {
        let caption = NSTextField(labelWithString: label)
        caption.alignment = .right
        caption.textColor = .secondaryLabelColor
        caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.lineBreakMode = .byTruncatingTail
        return row([caption, view], alignment: .top)
    }

    /// A wrapping explanatory paragraph. Always width-constrained — a wrapping `NSTextField` with no
    /// width takes its *single-line* intrinsic width and overruns instead of wrapping.
    static func note(_ text: String, isWarning: Bool = false) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = isWarning ? .systemOrange : .secondaryLabelColor
        label.isSelectable = false
        label.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.noteWidth
        ).isActive = true
        return label
    }

    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.noteWidth
        ).isActive = true
        return line
    }

    /// Stack a tab's rows into a **scrolling** pane with the sheet's standard insets.
    ///
    /// Scrolling rather than a fixed pane, and that is not defensive coding — it is a bug this
    /// panel already had. The Permissions tab's rows want ~384 pt in a ~320 pt tab, and an
    /// `NSStackView` that cannot fit its arranged views does not overflow: it *compresses* them.
    /// Live, that crushed the first flag row until "Locked" overlapped "Hidden" and its checkbox
    /// disappeared entirely — a row silently missing from a permissions panel, which is the worst
    /// direction for this particular surface to fail in.
    ///
    /// A taller sheet would have hidden it in English and brought it straight back in Russian,
    /// where every caption and note is longer (docs/NOTES.md — the same family as the pack sheet's
    /// clipped label column). Letting the content scroll is the fix that does not depend on how
    /// long a translation turns out to be.
    static func pane(_ rows: [NSView], width: CGFloat) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The document view takes its height from the stack, so the scroll view knows how much
        // content there is; the width is pinned so nothing stretches horizontally. It must be
        // **flipped**: an ordinary `NSView` document is bottom-origin, which puts the first row at
        // the bottom of the clip view and everything above it out of sight — the tab comes up
        // blank, which is exactly what the first attempt did.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: width)
        ])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        // A document view under Auto Layout is not positioned by the scroll view — it has to be
        // pinned to the clip view itself, or it keeps whatever frame it was born with.
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor)
        ])
        return scrollView
    }

    private static func row(
        _ views: [NSView],
        alignment: NSLayoutConstraint.Attribute = .firstBaseline
    ) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = 8
        stack.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.noteWidth
        ).isActive = true
        return stack
    }
}

/// A top-origin container, so a scroll view's document lays its content out from the top down.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Shared widths, kept in one place so the rows, notes and separators line up with each other and
/// with the tab view they sit in.
///
/// Nonisolated on purpose: `AttributeRow`'s builders are reached from the tabs' construction, and a
/// `@MainActor` constant cannot be read from a nonisolated default value.
enum AttributesControllerLayout {
    /// The sheet's outer width.
    static let sheetWidth: CGFloat = 620
    /// The sheet's outer height. Sized so the densest tab fits without scrolling in English; a longer
    /// translation scrolls rather than compressing, which is the point of
    /// ``AttributeRow/pane(_:width:)`` being a scroll view.
    ///
    /// Sharing took that title from Permissions when the ACL editor landed: a list, its buttons, and
    /// a 12- or 13-row rights matrix under it. **The scroll view is the fix and this is the comfort**
    /// — measured live at 540, the last row of each column and the order footnote sat below the fold,
    /// reachable but not visible. Raising the height alone would be the trap NOTES.md names (fixed in
    /// English, back again in a longer language); the pane scrolls either way.
    static let sheetHeight: CGFloat = 620
    /// The width every tab's content is pinned to inside it.
    static let contentWidth: CGFloat = 580
    /// The usable width inside a tab, after the pane's own insets.
    static let noteWidth: CGFloat = contentWidth - 32
    /// The minimum height a tab's content area gets.
    static let tabHeight: CGFloat = 380
    /// The height of a table inside a tab (ACL entries, extended attributes).
    static let tableHeight: CGFloat = 250
    /// The ACL list is shorter than a plain table: it shares its tab with the per-entry editor below
    /// it, and a list nobody can see the rights of is not the trade to make. The pane scrolls, so a
    /// long list is reachable and a long translation cannot crush the rows.
    static let aclTableHeight: CGFloat = 120
    /// What the "Apply to enclosed items" footer row adds to the sheet, when a folder is involved.
    /// The sheet grows by it rather than the tabs shrinking — an `NSStackView` that cannot fit its
    /// arranged views compresses them, which is how a whole checkbox row once vanished from the
    /// Permissions tab with nothing logged (docs/NOTES.md).
    static let recursiveRowHeight: CGFloat = 34
}
