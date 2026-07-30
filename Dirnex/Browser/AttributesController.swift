import AppKit
import DirnexCore

/// The Get Info sheet (PLAN.md §M14 Slice 4) — what a file's permissions, flags, ownership, dates,
/// access-control list and extended attributes actually are.
///
/// **This pass is read-only, and that is most of the value.** Dirnex has read `FileEntry.permissions`
/// on every listing since M1 and displayed it nowhere, so before anything is editable there has to
/// be a surface that can be checked against `ls -le@` and `stat -f` — the OS as the independent
/// judge. Editing, the ACL editor, multi-selection and the recursive apply are the passes after this.
///
/// Four tabs rather than one long column: the panel is dense enough that a single scroll buries the
/// ACL, and the split is also what keeps each tab's construction in its own file under SwiftLint's
/// ceilings (docs/NOTES.md §"Lint ceilings"). Each table has its own controller object for the same
/// reason, and because the ACL's is the one the editor will grow from.
@MainActor
final class AttributesController: NSViewController {
    let snapshot: AttributesSnapshot

    private let tabView = NSTabView()
    /// Retained for the tables' lifetime — `NSTableView` holds its data source weakly.
    private var accessControlTable: AccessControlTableController?
    private var extendedAttributeTable: ExtendedAttributeTableController?

    init(snapshot: AttributesSnapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View

    override func loadView() {
        let container = EscapeDismissingView()
        container.onEscape = { [weak self] in self?.close(nil) }

        let stack = NSStackView(views: [makeHeader(), makeTabs(), makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            container.heightAnchor.constraint(
                equalToConstant: AttributesControllerLayout.sheetHeight
            )
        ])
        view = container
    }

    /// The sheet's outer width. Every tab's content is pinned to ``contentWidth`` inside it, so a
    /// longer translation truncates its own label rather than widening the sheet (docs/NOTES.md —
    /// the pack sheet's fixed label column, and the sync sheet's segmented controls).
    static let sheetWidth = AttributesControllerLayout.sheetWidth
    static let contentWidth = AttributesControllerLayout.contentWidth

    @objc private func close(_ sender: Any?) { dismiss(sender) }
}

// MARK: - Construction

private extension AttributesController {
    /// Icon, name and the one-line summary — the same three things a Finder Get Info leads with.
    func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSWorkspace.shared.icon(forFile: snapshot.entry.path.path)
        icon.imageScaling = .scaleProportionallyUpOrDown
        // An icon defends its image's size at priority 750 and would push the sheet wider than the
        // display (docs/NOTES.md); it is a passenger in this layout, so both priorities go to the
        // floor and the constraints below are what size it.
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])

        let name = NSTextField(labelWithString: snapshot.entry.name)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle

        let subtitle = NSTextField(labelWithString: headerSummary())
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let header = NSStackView(views: [icon, text])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return header
    }

    /// Kind and size, as whole clauses joined by `·`.
    func headerSummary() -> String {
        var parts = [AttributeFormatting.kindDescription(of: snapshot)]
        if snapshot.entry.kind == .file {
            parts.append(AttributeFormatting.byteSize(snapshot.entry.byteSize))
        }
        return parts.joined(separator: " · ")
    }

    func makeTabs() -> NSView {
        addTab(
            title: String(
                localized: "General",
                comment: "Info panel tab: kind, size, location and the three dates."
            ),
            view: makeGeneralTab()
        )
        addTab(
            title: String(
                localized: "Permissions",
                comment: "Info panel tab: owner, group, the mode bits and the BSD file flags."
            ),
            view: makePermissionsTab()
        )

        let accessControl = AccessControlTableController(
            list: snapshot.accessControlList,
            kind: snapshot.entry.kind
        )
        accessControlTable = accessControl
        addTab(
            title: String(
                localized: "Sharing",
                comment: "Info panel tab: the access control list (ACL) entries, in order."
            ),
            view: accessControl.makeView(width: Self.contentWidth)
        )

        let extended = ExtendedAttributeTableController(attributes: snapshot.extendedAttributes)
        extendedAttributeTable = extended
        addTab(
            title: String(
                localized: "Attributes",
                comment: "Info panel tab: the item's extended attributes (xattrs)."
            ),
            view: extended.makeView(width: Self.contentWidth)
        )

        tabView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            tabView.heightAnchor.constraint(
                greaterThanOrEqualToConstant: AttributesControllerLayout.tabHeight
            )
        ])
        return tabView
    }

    func addTab(title: String, view: NSView) {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        tabView.addTabViewItem(item)
    }

    func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let doneButton = NSButton(
            title: String(localized: "Done", comment: "Button that closes a results sheet."),
            target: self,
            action: #selector(close(_:))
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let footer = NSStackView(views: [spacer, doneButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return footer
    }
}
