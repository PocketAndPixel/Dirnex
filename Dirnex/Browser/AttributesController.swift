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
    /// Retained for the tables' lifetime — `NSTableView` holds its data source weakly. The ACL one is
    /// also where the Sharing tab's working list lives, so Save reads its edits back through it.
    var accessControlTable: AccessControlTableController?
    private var extendedAttributeTable: ExtendedAttributeTableController?

    /// The ACL as the Sharing tab currently has it, or what was read when that tab built no editor.
    var workingAccessControlList: AccessControlList {
        accessControlTable?.list ?? snapshot.accessControlList
    }

    /// Whether the ACL differs from what was read — the diff contract applied to the one part of the
    /// panel that is an ordered list rather than a field. Whole-value, because entry order is
    /// meaning: two lists with the same entries in a different order are a real, different change.
    var accessControlListChanged: Bool {
        workingAccessControlList != snapshot.accessControlList
    }

    // MARK: - Editing (mode bits and BSD flags — PLAN.md §M14 Slice 4)

    /// The mutable copy the Permissions tab's checkboxes drive. Starts equal to what was read;
    /// `AttributeDiff(from: snapshot.attributes, to: working)` is what Save applies, so a field the
    /// user never touched is never written — the diff-based model the whole slice rests on.
    var working: FileAttributes

    /// Whether the item is the caller's to change unprivileged — they own it, or they are root.
    ///
    /// A file owned by **someone else is still editable** now (Slice 5): its Save routes through the
    /// administrator escalation instead of being refused. So `ownsItem` no longer gates *whether* the
    /// controls are live — ``canEdit`` does that, and is always true for the real local item Get Info
    /// handles. It gates the two things escalation does not yet cover: the "Apply to enclosed items"
    /// footer (a recursive apply over a tree the user does not own is a follow-on) and the
    /// Permissions-tab note that says a Save here will ask for a password.
    let ownsItem: Bool

    /// Whether the sheet offers editing at all. Always true now: an owner edits unprivileged, and a
    /// non-owner edits through Slice 5's escalation (``AttributesController+Escalation``), so the
    /// read-only, Done-only sheet is gone. A genuinely unwritable case — a read-only volume — still
    /// surfaces its error at Save rather than being predicted here; the field stays so every
    /// control-liveness site reads as "is editing offered" rather than hard-coding `true`.
    let canEdit: Bool

    /// The copyable "run it yourself" field in the escalation dialog — retained so its Copy button can
    /// read it back (``AttributesController+Escalation``). `NSButton.target` is weak, and the field
    /// outlives the transient alert only through this reference.
    weak var escalationCommandField: NSTextField?

    /// Journal a committed change so ⌘Z reverses it — set by the pane to its window's undo surface.
    var recordUndo: ((UndoRecord) -> Void)?
    /// Hand a recursive apply to the window's operation queue — set by the pane. A tree walk is not
    /// the sheet's to run: it can cover a hundred thousand items and needs the determinate bar,
    /// pause and cancel a copy gets, so the sheet only ever describes the job.
    var enqueueRecursive: ((AttributeApplyJob, [FileEntry]) -> Void)?

    /// The footer's "Apply to enclosed items" control, present only for a directory — there is
    /// nothing enclosed in a file. Retained for the sheet's lifetime; `NSControl.target` is weak.
    var recursiveOptions: RecursiveApplyOptions?
    /// Re-list the pane after a change lands, so a new `UF_HIDDEN` or mode shows at once — set by the
    /// pane. Kept separate from ``recordUndo`` because one is the window's job and the other the pane's.
    var onApplied: (() -> Void)?

    /// One mode-grid checkbox and the bit it stands for. A struct rather than a 3-tuple, which
    /// SwiftLint's `large_tuple` forbids.
    struct ModeCheckbox {
        let box: NSButton
        let cls: POSIXPermissions.Class
        let access: POSIXPermissions.Access
    }

    /// One editable timestamp: the control, which of the three it is, and **the value the control was
    /// born with**.
    ///
    /// That last field is not bookkeeping — it is what keeps an untouched picker from writing.
    /// `NSDatePicker` resolves to whole seconds while a real `st_mtime` carries microseconds, so
    /// reading `dateValue` back unconditionally makes every field differ from what was read the moment
    /// the sheet opens: Save lights up with nothing edited and a `utimes` runs on Save for three dates
    /// nobody touched. Comparing against the value the picker was *given* is what makes "a field left
    /// alone is never written" true at this control's granularity.
    struct DateField {
        let picker: NSDatePicker
        let kind: DateFieldKind
        let initial: Date
    }

    /// Which of the three timestamps a ``DateField`` drives. A sibling of `DateField` rather than a
    /// type nested inside it — SwiftLint allows one level of nesting, not two.
    enum DateFieldKind { case access, modification, creation }

    /// The live checkboxes, kept so one `editChanged` handler can rebuild ``working`` from all of them
    /// at once (simpler and less error-prone than each button carrying its own bit) and so Save's
    /// enablement and the Mode echo can refresh together.
    var modeBoxes: [ModeCheckbox] = []
    var setUserIDBox: NSButton?
    var setGroupIDBox: NSButton?
    var stickyBox: NSButton?
    var flagBoxes: [(box: NSButton, flag: BSDFileFlags)] = []
    /// The group picker, whose items carry their gid as `tag`.
    var groupPopup: NSPopUpButton?
    /// The three timestamp controls, in whatever order the General tab built them.
    var dateFields: [DateField] = []
    /// The `Mode:` value field, updated live as the boxes change so the octal echo never disagrees
    /// with the grid.
    var modeValueField: NSTextField?
    weak var saveButton: NSButton?

    /// Who is making the change. Stored rather than re-read so the group the picker offers and the
    /// privilege check Save runs can never disagree about the caller's memberships.
    let actor: UserContext

    init(snapshot: AttributesSnapshot) {
        self.snapshot = snapshot
        working = snapshot.attributes
        actor = UserContext.current()
        ownsItem = actor.isSuperUser || snapshot.attributes.ownerID == actor.userID
        canEdit = true
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
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            // A directory's sheet is one row taller, rather than squeezing the tabs: an NSStackView
            // that cannot fit its arranged views *compresses* them, which is how a whole row went
            // missing from this very panel once (docs/NOTES.md).
            container.heightAnchor.constraint(
                equalToConstant: AttributesControllerLayout.sheetHeight
                    + (recursiveOptions == nil ? 0 : AttributesControllerLayout.recursiveRowHeight)
            )
        ])
        view = container
    }

    /// The "Apply to enclosed items" row, for a directory the user may edit. A file has nothing
    /// enclosed, and a read-only sheet has no Save for it to qualify.
    private func makeRecursiveOptions() -> NSView? {
        // Only for a directory the caller owns: a recursive apply over a tree they do not own would
        // need to escalate every item, which Slice 5 leaves as a follow-on — the flat escalation
        // covers the single item on screen, not a walk.
        guard ownsItem, snapshot.entry.kind == .directory else { return nil }
        let options = RecursiveApplyOptions()
        options.onChange = { [weak self] in self?.refreshSaveEnabled() }
        recursiveOptions = options
        return options.makeView(width: Self.contentWidth)
    }

    /// The sheet's outer width. Every tab's content is pinned to ``contentWidth`` inside it, so a
    /// longer translation truncates its own label rather than widening the sheet (docs/NOTES.md —
    /// the pack sheet's fixed label column, and the sync sheet's segmented controls).
    static let sheetWidth = AttributesControllerLayout.sheetWidth
    static let contentWidth = AttributesControllerLayout.contentWidth

    @objc private func close(_ sender: Any?) { dismiss(sender) }

    /// The note a tab shows when the item belongs to someone else: it is still editable, but saving
    /// will ask for an administrator password (Slice 5). Distinct from the old read-only note — the
    /// controls are now live, so this sets the expectation rather than explaining why they are off.
    func makeNotOwnerNote() -> NSView {
        AttributeRow.note(String(
            localized: """
            You don’t own this item, so saving a change will ask for your administrator password.
            """,
            comment: "Info panel note when the user does not own the item; a Save will need root."
        ))
    }
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
            kind: snapshot.entry.kind,
            canEdit: canEdit
        )
        accessControl.onChange = { [weak self] in self?.refreshSaveEnabled() }
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

    /// A read-only panel closes with a single **Done**; an editable one commits with **Save** and
    /// discards with **Cancel**. Save is the default button (⏎) but starts disabled — there is nothing
    /// to save until a box is toggled — and Cancel doubles as the Escape target the whole sheet
    /// already honours (``EscapeDismissingView``), so discarding an edit is the same gesture as
    /// closing a read-only view.
    func makeFooter() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var buttons: [NSView] = [spacer]
        if canEdit {
            let cancel = NSButton(
                title: String(localized: "Cancel", comment: "Button that discards an edit."),
                target: self,
                action: #selector(close(_:))
            )
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"

            let save = NSButton(
                title: String(localized: "Save", comment: "Button that applies attribute edits."),
                target: self,
                action: #selector(saveAttributes(_:))
            )
            save.bezelStyle = .rounded
            save.keyEquivalent = "\r"
            save.isEnabled = false
            saveButton = save
            buttons.append(contentsOf: [cancel, save])
        } else {
            let done = NSButton(
                title: String(localized: "Done", comment: "Button that closes a results sheet."),
                target: self,
                action: #selector(close(_:))
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
}
