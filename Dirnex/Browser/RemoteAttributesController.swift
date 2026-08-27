import AppKit
import DirnexCore

/// Get Info for a row that is not on this Mac (PLAN.md §M24 Slice 7) — a server's object, an
/// archive member, a hit in a results tab that is either.
///
/// **A separate panel rather than the four-tab one with its controls switched off**, because the
/// two describe different things. `AttributesController` is built on an `lstat`, an `acl_get_file`
/// and a `listxattr`, and three of its four tabs would have nothing at all to say here: no remote
/// listing carries an access-control list, extended attributes, an access time or a birth time.
/// Degrading it would leave the mode grid — the one control a reader trusts most — standing over a
/// value the server may never have reported.
///
/// **The rule the whole panel is built on: a field with no answer is *absent*, never blank and
/// never a stand-in.** That reads as obvious and was not the state of the code. S3 and FTP's
/// DOS/IIS dialect both synthesized `0o755`/`0o644`, under a comment explaining that `0` "would
/// render every remote row as unreadable in the permissions column" — and the columns are `name`,
/// `size` and `date`. The invented mode reached nothing for as long as nothing displayed it, and
/// this panel is the reader that would have drawn it as the server's own word (see
/// ``FileEntry/permissions``, now optional for exactly this reason).
///
/// Read-only, and that is the whole slice: a panel that shows a mode it cannot change is honest,
/// and one that offers a change it cannot make is not. Writing is M25's.
@MainActor
final class RemoteAttributesController: NSViewController {
    /// Internal rather than private: Swift's `private` does not cross files, and the notes and
    /// footer live in `RemoteAttributesController+Notes` to keep both files under SwiftLint's
    /// `file_length` and `type_body_length` ceilings (docs/NOTES.md ▸ Lint ceilings).
    let entry: FileEntry

    init(entry: FileEntry) {
        self.entry = entry
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

        DialogLayout.fill(container, with: [makeHeader(), makeBody(), makeFooter()])
        container.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.sheetWidth
        ).isActive = true
        view = container
    }

    @objc func close(_ sender: Any?) { dismiss(sender) }

    // MARK: - Header

    /// Icon, name, and the kind-and-size summary the local panel leads with.
    ///
    /// The icon is typed by the row's **name**, never by its path: there is no file here to ask
    /// LaunchServices about, and `NSWorkspace.icon(forFile:)` on a path that does not exist answers
    /// a generic document for everything. It is the rule Open With settled on one slice ago for the
    /// same reason, reached through `FileIconProvider`, which every remote row in the pane already
    /// draws itself with — so the panel and the row it was opened from cannot disagree.
    func makeHeader() -> NSView {
        let icon = NSImageView()
        icon.image = FileIconProvider.icon(for: entry)
        icon.imageScaling = .scaleProportionallyUpOrDown
        // An image view defends its image's size at priority 750 and would push the window wider
        // than the display (docs/NOTES.md); both priorities go to the floor so the constraints size
        // it instead.
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48)
        ])

        let name = NSTextField(labelWithString: entry.name)
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
        header.widthAnchor.constraint(
            equalToConstant: AttributesControllerLayout.contentWidth
        ).isActive = true
        return header
    }

    /// Kind, and a size only where one means something: a folder's `byteSize` is its own bookkeeping
    /// locally and a flat `0` for an S3 common prefix, so it is never a total of what is inside.
    private func headerSummary() -> String {
        var parts = [
            AttributeFormatting.kindDescription(of: entry.kind, isSymlink: entry.kind == .symlink)
        ]
        if entry.kind == .file { parts.append(AttributeFormatting.byteSize(entry.byteSize)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Body

    /// One fact the panel can state. A pure list of these is what the body is built from, so "which
    /// rows does this row deserve" is answerable — and testable — without a window, a pane or a
    /// presented dialog. The same split `AlertKeyCatcher` needed for its keys: the rule is the part
    /// worth pinning, and presenting a real window in the test host destabilizes its neighbours
    /// (docs/NOTES.md ▸ Testing).
    enum Field: Equatable {
        case location, pointsTo, modified, permissions, owner, group, entityTag

        /// Which run of rows this belongs to. A separator is drawn where the group changes, so the
        /// rule lives here rather than in a hand-maintained list of insertion points that would go
        /// wrong the first time a field became conditional.
        var group: Int {
            switch self {
            case .location, .pointsTo: 0
            case .modified: 1
            case .permissions, .owner, .group: 2
            case .entityTag: 3
            }
        }
    }

    /// Exactly the facts this entry carries, in display order.
    ///
    /// **Every one of these is a presence test, never a fallback.** That is the whole slice: a mode
    /// this listing did not report has no row, rather than a row reading `0` or a plausible
    /// `rw-r--r--` that the server never said.
    static func fields(for entry: FileEntry) -> [Field] {
        var fields: [Field] = [.location]
        if entry.symlinkDestination != nil { fields.append(.pointsTo) }
        if entry.hasModificationDate { fields.append(.modified) }
        if entry.permissions != nil { fields.append(.permissions) }
        if entry.ownerName != nil { fields.append(.owner) }
        if entry.groupName != nil { fields.append(.group) }
        if entry.entityTag != nil { fields.append(.entityTag) }
        return fields
    }

    func makeBody() -> NSView {
        var rows: [NSView] = []
        var lastGroup: Int?
        for field in Self.fields(for: entry) {
            if let lastGroup, lastGroup != field.group { rows.append(AttributeRow.separator()) }
            lastGroup = field.group
            rows.append(row(for: field))
        }
        rows.append(contentsOf: makeNotes())
        return AttributeRow.pane(rows, width: AttributesControllerLayout.contentWidth)
    }

    private func row(for field: Field) -> NSView {
        switch field {
        case .location:
            AttributeRow.make(
                label: String(
                    localized: "Where:",
                    comment: "Info panel field label: the folder the item is in."
                ),
                value: entry.path.parent?.path ?? entry.path.path
            )
        case .pointsTo:
            AttributeRow.make(
                label: String(
                    localized: "Points to:",
                    comment: "Info panel field label: what a symbolic link resolves to."
                ),
                value: entry.symlinkDestination ?? ""
            )
        // Only a modification date. A remote listing carries no access time and no birth time, so
        // the two the local panel shows beside this one are absent rather than repeated from it —
        // and `unknownDate` is a real answer from several backends (an S3 folder is a common prefix
        // rather than an object, so it has no `LastModified` at all).
        case .modified:
            AttributeRow.make(
                label: String(
                    localized: "Modified:",
                    comment: "Info panel field label: last content modification (st_mtime)."
                ),
                value: AttributeFormatting.date(entry.modificationDate)
            )
        case .permissions:
            AttributeRow.make(
                label: String(
                    localized: "Permissions:",
                    comment: "Info panel field label: the POSIX mode bits."
                ),
                value: AttributeFormatting.modeDescription(
                    POSIXPermissions(rawValue: entry.permissions ?? 0)
                ),
                monospaced: true
            )
        // Text, exactly as the source spelled it, and never resolved against this Mac — see
        // `FileEntry.ownerName`. A server's `501` put through `getpwuid` here would draw the local
        // account of whoever is reading the panel over a file belonging to a stranger.
        case .owner:
            AttributeRow.make(
                label: String(
                    localized: "Owner:",
                    comment: "Info panel field label: the owning user, as the server named it."
                ),
                value: entry.ownerName ?? ""
            )
        case .group:
            AttributeRow.make(
                label: String(
                    localized: "Group:",
                    comment: "Info panel field label: the owning group, as the server named it."
                ),
                value: entry.groupName ?? ""
            )
        case .entityTag:
            AttributeRow.make(
                label: String(
                    localized: "Entity tag:",
                    comment: "Info panel field label: the server's ETag for a stored object."
                ),
                value: entry.entityTag ?? "",
                monospaced: true
            )
        }
    }
}
