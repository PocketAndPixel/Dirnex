import AppKit
import DirnexCore

/// The Synchronize sheet's AppKit layout — the header, the two choice controls, the diff
/// table's columns and the footer.
///
/// Split from ``SyncDirectoriesController`` at M25 Slice 5c, when the two choice controls
/// stopped being fixed lists of three and two and the file crossed SwiftLint's 500-line
/// ceiling. The seam is the one the file already had between deciding and drawing, and the three
/// helpers below moved with it because they are the drawing's alone.
extension SyncDirectoriesController {
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }

    private func segmentWidth(for title: String, in control: NSSegmentedControl) -> CGFloat {
        let font = control.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 32
    }

    private func spacer(width: CGFloat) -> NSView {
        let view = NSView()
        if width > 0 {
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
        } else {
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        return view
    }

    func makeHeader() -> NSView {
        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.stringValue = "\(abbreviate(leftDir))   ⟷   \(abbreviate(rightDir))"
        headerLabel.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return headerLabel
    }

    func makeControls() -> NSView {
        let directionTitles = directions.map(Self.title(for:))
        directionControl.segmentCount = directionTitles.count
        for (index, title) in directionTitles.enumerated() {
            directionControl.setLabel(title, forSegment: index)
            directionControl.setWidth(
                segmentWidth(for: title, in: directionControl),
                forSegment: index
            )
        }
        directionControl.selectedSegment = directions.firstIndex(of: direction) ?? 0
        directionControl.target = self
        directionControl.action = #selector(directionChanged(_:))

        let comparisonTitles = comparisons.map(Self.title(for:))
        comparisonControl.segmentCount = comparisonTitles.count
        for (index, title) in comparisonTitles.enumerated() {
            comparisonControl.setLabel(title, forSegment: index)
        }
        comparisonControl.selectedSegment = comparisons.firstIndex(of: comparison) ?? 0
        comparisonControl.target = self
        comparisonControl.action = #selector(comparisonChanged(_:))

        let hint = label(String(
            localized: "Right-click a row to change its action",
            comment: "Sync sheet hint above the diff table."
        ))
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        // The hint is the one element that yields. It must truncate before either choice control
        // loses a word in a longer translation.
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let directionRow = NSStackView(views: [
            label(
                String(
                    localized: "Direction:",
                    comment: "Sync sheet label before the direction control."
                )
            ),
            directionControl, spacer(width: 0)
        ])
        directionRow.orientation = .horizontal
        directionRow.spacing = 8
        directionRow.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let comparisonRow = NSStackView(views: [
            label(
                String(
                    localized: "Compare by:",
                    comment: "Sync sheet label before the comparison-method control."
                )
            ),
            comparisonControl, spacer(width: 0)
        ])
        comparisonRow.orientation = .horizontal
        comparisonRow.spacing = 8
        comparisonRow.widthAnchor.constraint(equalToConstant: 680).isActive = true

        hint.widthAnchor.constraint(equalToConstant: 680).isActive = true

        let controls = NSStackView(views: [directionRow, comparisonRow, hint])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        return controls
    }

    func makeTable() -> NSView {
        addColumn("include", title: "", width: 26)
        addColumn(
            "name",
            title: String(
                localized: "Item",
                comment: "Sync diff table column header: the item's relative path."
            ),
            width: 300
        )
        // `displayName`, not `lastComponent`: at a backend root the latter is `"/"`, so a bucket or
        // a server home would head its column with a slash (docs/NOTES.md ▸ AppKit, a backend's root
        // is the third thing the compiler cannot see).
        addColumn("left", title: leftDir.displayName, width: 130)
        addColumn("action", title: "", width: 60)
        addColumn("right", title: rightDir.displayName, width: 130)
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self

        // Right-click a row to override its action (rebuilt per-click from the clicked row).
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        tableView.menu = rowMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: 680).isActive = true
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
        return scrollView
    }

    func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    func makeFooter() -> NSView {
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let cancelButton = NSButton(
            title: String(localized: "Cancel", comment: "Dismiss button."),
            target: self,
            action: #selector(cancel(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        syncButton.title = String(
            localized: "Synchronize",
            comment: "Confirm button of the sync delete prompt and the sync sheet."
        )
        syncButton.bezelStyle = .rounded
        syncButton.keyEquivalent = "\r"
        syncButton.target = self
        syncButton.action = #selector(apply(_:))

        // The label is the arranged view that gives way when the row is short of room. Everything
        // in this footer resists compression equally by default, so without this the stack squeezes
        // whichever it likes — and a crushed *button* is a control nobody can read, where a
        // truncated status still says most of what it said and keeps the rest in its tooltip
        // (docs/NOTES.md ▸ Localization, the same fix the sync sheet's controls row needed).
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [statusLabel, spacer(width: 0), cancelButton, syncButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 680).isActive = true
        return footer
    }

    static func title(for direction: SyncDirection) -> String {
        switch direction {
        case .leftToRight:
            String(
                localized: "Left → Right",
                comment: "Sync direction: mirror the left folder onto the right."
            )
        case .bidirectional:
            String(localized: "Both Directions", comment: "Sync direction: reconcile both folders.")
        case .rightToLeft:
            String(
                localized: "Right → Left",
                comment: "Sync direction: mirror the right folder onto the left."
            )
        }
    }

    static func title(for comparison: SyncComparison) -> String {
        switch comparison {
        case .size:
            // The comment is the file-list column header's, repeated **verbatim**: it is the same
            // key, and two sites commenting one key differently hand the translator whichever
            // `xcstringstool` kept (docs/NOTES.md ▸ Localization). Why size-only is the honest
            // comparison on a server belongs in ``SyncComparison/size``, not in a translator note.
            String(
                localized: "Size",
                comment: "File-list column header: the file's size."
            )
        case .sizeAndDate:
            String(
                localized: "Size & Date",
                comment: "Sync comparison method: compare by size and modification date."
            )
        case .content:
            String(localized: "Content", comment: "Sync comparison method: compare byte-for-byte.")
        }
    }
}
