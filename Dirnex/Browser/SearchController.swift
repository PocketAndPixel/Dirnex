import AppKit
import DirnexCore

/// The Find Files dialog (⌥F7 / palette "Find Files…") — a small form over a `FileQuery`
/// (PLAN.md §M4 "Search … with filter chips (kind, size, date)"). The user fills in any
/// combination of a name substring, a content substring, and the kind/size/date chips, picks a
/// scope, and "Find" hands the query back to the panel, which runs `mdfind` and shows the hits
/// in a virtual results panel.
///
/// Presented via `presentAsMovableWindow` (which retains it for its on-screen lifetime). All the query
/// logic is the tested `DirnexCore.FileQuery`; this is just the AppKit shell that binds
/// controls to it.
@MainActor
final class SearchController: NSViewController {
    /// Where the search will run.
    enum Scope: Equatable {
        /// The folder the pane is showing, and everything under it.
        case currentFolder
        /// Everything reachable — every indexed volume on the Spotlight route, and the connection's
        /// or archive's own root on a walk. One case rather than two because the *dialog* asks one
        /// question ("here, or everything?"); which "everything" it resolves to belongs to the pane,
        /// which knows what it is connected to.
        case everything
    }

    /// The folder the "This Folder" scope option searches within, shown in that option's title.
    private let currentFolderName: String
    /// What this scope can actually be asked about — the fields outside it are not drawn at all
    /// (PLAN.md §M22).
    ///
    /// Hidden rather than disabled, deliberately. A grayed-out "Content contains" is a promise the
    /// app is not keeping and an invitation to go looking for the setting that would enable it,
    /// where an absent row reads as what it is: this place answers questions about names, kinds,
    /// sizes and dates.
    private let fields: SearchFields
    /// What the whole connection is called, when the second scope option means "everything on this
    /// server" rather than "everywhere Spotlight indexed" — `nil` on the local route.
    private let connectionRootTitle: String?
    /// Handed the assembled query and the chosen scope when the user commits. The panel runs the
    /// search.
    var onSearch: ((FileQuery, _ scope: Scope) -> Void)?

    // Controls
    private let nameField = NSTextField()
    private let contentField = NSTextField()
    private let kindPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private let datePopup = NSPopUpButton()
    /// The tag chips (PLAN.md §M6 "Finder tags: … filter chips in search"). An `NSTokenField`
    /// because a tag *is* a token: it rounds each name into a chip you can delete as one, which is
    /// what the plan's word describes, and it completes against the names already in use rather
    /// than asking the user to spell them from memory. Several tags narrow (they AND) — see
    /// `FileQuery.tags`.
    private let tagField = NSTokenField()
    private let scopePopup = NSPopUpButton()
    private let findButton = NSButton()

    init(currentFolderName: String, fields: SearchFields, connectionRootTitle: String?) {
        self.currentFolderName = currentFolderName
        self.fields = fields
        self.connectionRootTitle = connectionRootTitle
        super.init(nibName: nil, bundle: nil)
        title = DialogTitle.ofCommand("go.search")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        DialogLayout.fill(container, with: [makeControlsGrid(), makeFooter()], spacing: 16)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 552)
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateFindEnabled()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    private func makeControlsGrid() -> NSView {
        configure(nameField, placeholder: String(
            localized: "part of the file name",
            comment: "Find Files: placeholder in the Name-contains field."
        ))
        configure(contentField, placeholder: String(
            localized: "text inside the file",
            comment: "Find Files: placeholder in the Content-contains field."
        ))
        configure(tagField, placeholder: String(
            localized: "Work, Red — all must match",
            comment: "Find Files: placeholder in the Tags field; example tag names, comma-separated."
        ))
        // Explicitly, through the `NSTokenField`-typed reference: `configure` takes an `NSTextField`,
        // and assigning the delegate through that would go via the superclass's setter.
        tagField.delegate = self
        // Comma, the separator the field already shows between chips, so typing reads the way the
        // result looks. Completion is immediate rather than on a delay: the list is a handful of
        // names held in memory, so there is nothing to wait for.
        tagField.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tagField.completionDelay = 0
        for (title, _) in SearchFilterOptions.kinds { kindPopup.addItem(withTitle: title) }
        for (title, _) in SearchFilterOptions.sizes { sizePopup.addItem(withTitle: title) }
        for (title, _) in SearchFilterOptions.ages { datePopup.addItem(withTitle: title) }
        scopePopup.addItem(withTitle: String(
            localized: "This Folder (“\(currentFolderName)”)",
            comment: "Find Files: the Search-in popup option scoping to the current folder; %@ is its name."
        ))
        scopePopup.addItem(withTitle: everythingScopeTitle)
        for popup in [kindPopup, sizePopup, datePopup] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }

        // Each row carries the field it asks about, so hiding one is a fact about the *scope* rather
        // than a row index somebody has to keep in step with the layout.
        let rows = [
            Row(.name, nameLabel, nameField),
            Row(.content, contentLabel, contentField),
            Row(.tags, tagsLabel, tagField),
            Row(.kind, kindLabel, kindPopup),
            Row(.size, sizeLabel, sizePopup),
            Row(.modified, dateLabel, datePopup),
            Row(nil, scopeLabel, scopePopup)
        ]

        let grid = NSGridView(views: rows.map { [$0.caption, $0.control] })
        for (index, row) in rows.enumerated() {
            guard let field = row.field, !fields.contains(field) else { continue }
            grid.row(at: index).isHidden = true
        }
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    /// One line of the form: the field it asks about (`nil` for the scope row, which is not a
    /// question about files), its caption, and its control.
    private struct Row {
        let field: SearchFields?
        let caption: NSView
        let control: NSView

        init(_ field: SearchFields?, _ caption: NSView, _ control: NSView) {
            self.field = field
            self.caption = caption
            self.control = control
        }
    }

    // The captions, each wrapped where it is written: `String(localized:)` takes a `StaticString`
    // comment, so a caption passed through a variable would be a bare literal the extractor never
    // sees (docs/NOTES.md ▸ Localization).
    private var nameLabel: NSTextField {
        label(String(localized: "Name contains:", comment: "Find Files: field label."))
    }

    private var contentLabel: NSTextField {
        label(String(localized: "Content contains:", comment: "Find Files: field label."))
    }

    private var tagsLabel: NSTextField {
        label(String(localized: "Tags:", comment: "Find Files: field label."))
    }

    private var kindLabel: NSTextField {
        label(String(localized: "Kind:", comment: "Find Files: field label."))
    }

    private var sizeLabel: NSTextField {
        label(String(localized: "Size:", comment: "Find Files: field label."))
    }

    private var dateLabel: NSTextField {
        label(String(localized: "Modified:", comment: "Find Files: field label."))
    }

    private var scopeLabel: NSTextField {
        label(String(localized: "Search in:", comment: "Find Files: field label."))
    }

    /// The second scope option. "Everywhere" is honest only where there is an index that spans
    /// volumes; on a server it would be a claim about the whole machine, when what is actually
    /// searched is the connection this pane is standing in.
    private var everythingScopeTitle: String {
        guard let connectionRootTitle else {
            return String(
                localized: "Everywhere",
                comment: "Find Files: the Search-in popup option searching the whole index."
            )
        }
        return String(
            localized: "All of “\(connectionRootTitle)”",
            comment: """
            Find Files: the Search-in popup option covering a whole connection or archive; \
            %@ is its name, such as a bucket, a server or an archive file.
            """
        )
    }

    private func makeFooter() -> NSView {
        let cancelButton = NSButton(
            title: String(localized: "Cancel", comment: "Button that dismisses a dialog."),
            target: self,
            action: #selector(cancel(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Esc

        findButton.title = String(
            localized: "Find",
            comment: "Find Files: the button that runs the search."
        )
        findButton.bezelStyle = .rounded
        findButton.keyEquivalent = "\r"
        findButton.target = self
        findButton.action = #selector(find(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, cancelButton, findButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return footer
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: Any?) {
        updateFindEnabled()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss(sender)
    }

    @objc private func find(_ sender: Any?) {
        let query = currentQuery()
        guard !query.isEmpty else { return }
        onSearch?(query, scopePopup.indexOfSelectedItem == 0 ? .currentFolder : .everything)
        dismiss(sender)
    }

    // MARK: - Query

    /// The query as the controls currently stand.
    ///
    /// A field the scope cannot answer contributes nothing, whatever it happens to hold. It is
    /// hidden and therefore always empty in practice — but the whole design rests on a query never
    /// carrying a term that will be silently ignored, and resting that on "the row isn't on screen"
    /// makes it a fact about the *layout*. Reading it from `fields` makes it a fact about the place
    /// being searched, which is what it is.
    private func currentQuery() -> FileQuery {
        let kind = SearchFilterOptions.kinds[max(0, kindPopup.indexOfSelectedItem)].kind
        return FileQuery(
            nameContains: fields.contains(.name) ? nameField.stringValue : "",
            contentContains: fields.contains(.content) ? contentField.stringValue : "",
            kinds: fields.contains(.kind) ? kind.map { [$0] } ?? [] : [],
            minSizeBytes: fields.contains(.size)
                ? SearchFilterOptions.sizes[max(0, sizePopup.indexOfSelectedItem)].bytes
                : nil,
            modifiedWithin: fields.contains(.modified)
                ? SearchFilterOptions.ages[max(0, datePopup.indexOfSelectedItem)].age
                : nil,
            tags: fields.contains(.tags) ? enteredTags : []
        )
    }

    /// The tag names in the field — chips the user has committed **and** whatever they are still
    /// typing.
    ///
    /// Read from `stringValue` rather than `objectValue` precisely to get that second half.
    /// `objectValue` holds only tokenized chips, so a tag typed without a trailing comma would be
    /// invisible here — which would not merely drop it from the search: with a tag as the only term,
    /// `isEmpty` would keep the Find button **disabled**, and the user could not run the search at
    /// all. `stringValue` reports the field live as it is typed (the same property the name/content
    /// fields already rely on), joining committed chips with the tokenizing comma.
    private var enteredTags: Set<String> {
        Set(
            tagField.stringValue
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// "Find" is enabled only when the query asks for *something* — otherwise it would list the
    /// entire index. Recomputed as the fields and popups change.
    private func updateFindEnabled() {
        findButton.isEnabled = !currentQuery().isEmpty
    }

    // MARK: - Small helpers

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func configure(_ field: NSTextField, placeholder: String) {
        field.keepToOneLine()
        field.placeholderString = placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
    }
}

// MARK: - Live enable as the user types, and tag completion

/// `NSTokenFieldDelegate` refines `NSTextFieldDelegate`, so the one conformance serves both the
/// plain fields' live enabling and the tag field's completion.
extension SearchController: NSTokenFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateFindEnabled()
    }

    /// Complete a half-typed chip against the tags we know about: the seven macOS ships with, plus
    /// every name seen while browsing this session (`FinderTagProvider.knownTagNames`).
    ///
    /// Prefix-matched and case-insensitive, which is the system's own rule for identifying a tag —
    /// typing `work` should offer `Work`, because to macOS they are the same tag.
    func tokenField(
        _ tokenField: NSTokenField,
        completionsForSubstring substring: String,
        indexOfToken tokenIndex: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
        let prefix = substring.trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return [] }
        return FinderTagProvider.shared.knownTagNames
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
