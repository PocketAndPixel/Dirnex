import AppKit
import DirnexCore

/// The Get Info sheet for a **multi-selection** (PLAN.md §M14 Slice 4): change the mode bits, BSD
/// flags, group and dates of several items at once.
///
/// The whole design turns on one word — a bulk edit applies a *patch*, not a value. Two selected
/// files that disagree on a bit must keep disagreeing on it unless the user touches that bit, so the
/// controls are **tri-state**: a checkbox the items agree on shows on or off, one they disagree on
/// shows the mixed dash and *means "leave each item alone"*. Only a control the user moves off its
/// starting state is written, and it is written through the tested ``AttributePatch`` → per-item
/// ``AttributeDiff`` → ``AttributeChangePlan`` path, once per item, with one undo record spanning the
/// whole batch (docs/NOTES.md — the Multi-Rename precedent).
///
/// It reuses the single-item sheet's layout vocabulary (``AttributeRow``, ``AttributesControllerLayout``,
/// ``AttributeFormatting``) but is its own controller rather than a mode of ``AttributesController``:
/// that one is built around a single ``AttributesSnapshot`` — one entry, one ACL, one xattr list — and
/// threading "or N items, and no ACL, and tri-state" through every field would be worse than a second,
/// focused type (docs/NOTES.md §"Lint ceilings" — split by concept).
///
/// **ACLs and extended attributes are deliberately absent.** An ordered, kind-dependent access-control
/// list has no meaningful "apply a diff to N items", so bulk editing does not touch it; a note points
/// the user at editing those one at a time. Owner is read-only for the same reason it is in the
/// single-item sheet — `chown` is `EPERM` even on your own file.
@MainActor
final class MultiAttributesController: NSViewController {
    /// One selected item, read once when the sheet opens: its current attributes, whether it is a
    /// symlink (so the commit acts on the link, per item), and whether it carries an ACL (so the
    /// panel can say the mode is not the whole story, the same honesty the single-item sheet owes).
    struct Item {
        let entry: FileEntry
        let attributes: FileAttributes
        let isSymlink: Bool
        let hasAccessControlList: Bool
    }

    /// One tri-state mode checkbox and the bit it stands for, plus **the state it was born with** —
    /// which is what "leave alone" compares against. A struct, not a tuple: SwiftLint's `large_tuple`.
    struct ModeTri {
        let box: NSButton
        let cls: POSIXPermissions.Class
        let access: POSIXPermissions.Access
        let initial: NSControl.StateValue
    }

    /// The three special mode bits as tri-state boxes.
    struct SpecialTri {
        let box: NSButton
        let kind: SpecialKind
        let initial: NSControl.StateValue
    }

    enum SpecialKind { case setUserID, setGroupID, sticky }

    /// One tri-state BSD-flag checkbox.
    struct FlagTri {
        let box: NSButton
        let flag: BSDFileFlags
        let initial: NSControl.StateValue
    }

    /// One editable date: the picker, which of the three it is, and the **Change** checkbox that gates
    /// it. A date has no natural "mixed" checkbox state — a picker always shows *some* instant — so the
    /// opt-in is explicit: the picker is written only while its checkbox is on.
    struct DateRow {
        let enable: NSButton
        let picker: NSDatePicker
        let kind: DateKind
    }

    enum DateKind { case access, modification, creation }

    let items: [Item]
    let actor: UserContext

    /// Whether the offered controls are live. Bulk editing is unprivileged only when the caller owns
    /// **every** selected item (or is root); a selection that mixes owners would need Slice 5's
    /// escalation, so until then the controls are shown disabled with a note. A per-item root-only case
    /// an owner can still reach (a system-immutable file among the set) is caught at Save.
    let canEdit: Bool

    /// Journal the committed batch so one Cmd+Z reverses it — set by the pane to its window's undo
    /// surface, exactly as the single-item sheet's is.
    var recordUndo: ((UndoRecord) -> Void)?
    /// Re-list the pane after the change lands — set by the pane.
    var onApplied: (() -> Void)?
    /// Hand a recursive apply to the window's operation queue — set by the pane, exactly as the
    /// single-item sheet's is. A tree walk belongs on the queue, not in a sheet.
    var enqueueRecursive: ((AttributeApplyJob, [FileEntry]) -> Void)?

    /// The footer's "Apply to enclosed items" control, present only when a folder is among the
    /// selection. Retained for the sheet's lifetime; `NSControl.target` is weak.
    var recursiveOptions: RecursiveApplyOptions?

    var modeBoxes: [ModeTri] = []
    var specialBoxes: [SpecialTri] = []
    var flagBoxes: [FlagTri] = []
    var groupPopup: NSPopUpButton?
    var dateRows: [DateRow] = []
    weak var saveButton: NSButton?

    /// The popup tag that means "leave every item's group alone". A real gid is non-negative, so a
    /// negative sentinel can never collide with one.
    static let leaveGroupUnchanged = -1

    private let tabView = NSTabView()

    init(items: [Item]) {
        self.items = items
        // A local, not `self.actor`: referencing the member inside the `allSatisfy` closure would
        // capture `self` before `super.init`, which two-phase init forbids.
        let actor = UserContext.current()
        self.actor = actor
        canEdit = actor.isSuperUser || items.allSatisfy { $0.attributes.ownerID == actor.userID }
        super.init(nibName: nil, bundle: nil)
        title = DialogTitle.ofCommand("file.attributes")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View

    override func loadView() {
        let container = EscapeDismissingView()
        container.onEscape = { [weak self] in self?.close(nil) }

        var rows: [NSView] = [makeHeader(), makeTabs()]
        if let recursion = makeRecursiveOptions() { rows.append(recursion) }
        rows.append(makeFooter())

        let stack = NSStackView(views: rows)
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
            container.widthAnchor.constraint(equalToConstant: AttributesControllerLayout.sheetWidth),
            container.heightAnchor.constraint(
                equalToConstant: AttributesControllerLayout.sheetHeight
                    + (recursiveOptions == nil ? 0 : AttributesControllerLayout.recursiveRowHeight)
            )
        ])
        view = container
    }

    /// The "Apply to enclosed items" row, offered when at least one selected item is a folder — a
    /// selection of plain files has nothing enclosed to reach.
    private func makeRecursiveOptions() -> NSView? {
        guard canEdit, items.contains(where: { $0.entry.kind == .directory }) else { return nil }
        let options = RecursiveApplyOptions()
        options.onChange = { [weak self] in self?.refreshSaveEnabled() }
        recursiveOptions = options
        return options.makeView(width: Self.contentWidth)
    }

    static let contentWidth = AttributesControllerLayout.contentWidth

    @objc func close(_ sender: Any?) { dismiss(sender) }

    // MARK: - Tabs

    private func makeTabs() -> NSView {
        addTab(
            title: String(
                localized: "General",
                comment: "Info panel tab: what the selection is, and the three dates."
            ),
            view: makeGeneralTab()
        )
        addTab(
            title: String(
                localized: "Permissions",
                comment: "Info panel tab: group, the mode bits and the BSD file flags."
            ),
            view: makePermissionsTab()
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

    private func addTab(title: String, view: NSView) {
        let item = NSTabViewItem()
        item.label = title
        item.view = view
        tabView.addTabViewItem(item)
    }

    // MARK: - Header and footer

    private func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(named: NSImage.multipleDocumentsName)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])

        let name = NSTextField(labelWithString: MultiAttributeSummary.title(of: items))
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle

        let subtitle = NSTextField(labelWithString: MultiAttributeSummary.subtitle(of: items))
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

    private func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var buttons: [NSView] = [spacer]
        if canEdit {
            let cancel = NSButton(
                title: String(localized: "Cancel", comment: "Button that discards an edit."),
                target: self, action: #selector(close(_:))
            )
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"

            let save = NSButton(
                title: String(localized: "Save", comment: "Button that applies attribute edits."),
                target: self, action: #selector(saveAttributes(_:))
            )
            save.bezelStyle = .rounded
            save.keyEquivalent = "\r"
            save.isEnabled = false
            saveButton = save
            buttons.append(contentsOf: [cancel, save])
        } else {
            let done = NSButton(
                title: String(localized: "Done", comment: "Button that closes a results sheet."),
                target: self, action: #selector(close(_:))
            )
            done.bezelStyle = .rounded
            done.keyEquivalent = "\r"
            buttons.append(done)
        }
        let footer = NSStackView(views: buttons)
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return footer
    }

    /// The note every tab with controls shows when the selection is not all the user's to change.
    func makeNotOwnerNote() -> NSView {
        AttributeRow.note(String(
            localized: """
            You can view these, but they can only be changed when you own every selected item — one \
            or more of these belongs to someone else.
            """,
            comment: "Info panel note when a multi-selection includes items the user does not own."
        ))
    }
}
