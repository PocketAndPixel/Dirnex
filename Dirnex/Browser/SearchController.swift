import AppKit
import DirnexCore

/// The Find Files sheet (⌥F7 / palette "Find Files…") — a small form over a `SpotlightQuery`
/// (PLAN.md §M4 "Search … with filter chips (kind, size, date)"). The user fills in any
/// combination of a name substring, a content substring, and the kind/size/date chips, picks a
/// scope, and "Find" hands the query back to the panel, which runs `mdfind` and shows the hits
/// in a virtual results panel.
///
/// Presented via `presentAsSheet` (which retains it for its on-screen lifetime). All the query
/// logic is the tested `DirnexCore.SpotlightQuery`; this is just the AppKit shell that binds
/// controls to it.
@MainActor
final class SearchController: NSViewController {
    /// The folder the "This Folder" scope option searches within, shown in that option's title.
    private let currentFolderName: String
    /// Handed the assembled query and whether to scope it to the current folder (vs. everywhere)
    /// when the user commits. The panel runs the search.
    var onSearch: ((SpotlightQuery, _ scopeToCurrentFolder: Bool) -> Void)?

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
    /// `SpotlightQuery.tags`.
    private let tagField = NSTokenField()
    private let scopePopup = NSPopUpButton()
    private let findButton = NSButton()

    private let kindOptions: [(title: String, kind: SearchKind?)] =
        [
            (
                String(
                    localized: "Any kind",
                    comment: "Find Files: the Kind popup's no-filter option."
                ),
                nil
            )
        ]
        + SearchKind.allCases.map { (LocalizedCatalog.title(for: $0), $0) }

    private let sizeOptions: [(title: String, bytes: Int64?)] = [
        (
            String(localized: "Any size", comment: "Find Files: the Size popup's no-filter option."),
            nil
        ),
        (
            String(
                localized: "Larger than 1 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            1_048_576
        ),
        (
            String(
                localized: "Larger than 10 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            10_485_760
        ),
        (
            String(
                localized: "Larger than 100 MB",
                comment: "Find Files: a minimum-size filter option."
            ),
            104_857_600
        ),
        (
            String(
                localized: "Larger than 1 GB",
                comment: "Find Files: a minimum-size filter option."
            ),
            1_073_741_824
        )
    ]

    private let dateOptions: [(title: String, age: SearchAge?)] =
        [
            (
                String(
                    localized: "Any date",
                    comment: "Find Files: the Modified popup's no-filter option."
                ),
                nil
            )
        ]
        + SearchAge.allCases.map { (LocalizedCatalog.title(for: $0), $0) }

    init(currentFolderName: String) {
        self.currentFolderName = currentFolderName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View setup

    override func loadView() {
        let container = NSView()
        let stack = NSStackView(views: [makeControlsGrid(), makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 460)
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
        for (title, _) in kindOptions { kindPopup.addItem(withTitle: title) }
        for (title, _) in sizeOptions { sizePopup.addItem(withTitle: title) }
        for (title, _) in dateOptions { datePopup.addItem(withTitle: title) }
        scopePopup.addItem(withTitle: String(
            localized: "This Folder (“\(currentFolderName)”)",
            comment: "Find Files: the Search-in popup option scoping to the current folder; %@ is its name."
        ))
        scopePopup.addItem(withTitle: String(
            localized: "Everywhere",
            comment: "Find Files: the Search-in popup option searching the whole index."
        ))
        for popup in [kindPopup, sizePopup, datePopup] {
            popup.target = self
            popup.action = #selector(controlChanged(_:))
        }

        let grid = NSGridView(views: [
            [
                label(String(localized: "Name contains:", comment: "Find Files: field label.")),
                nameField
            ],
            [
                label(String(localized: "Content contains:", comment: "Find Files: field label.")),
                contentField
            ],
            [label(String(localized: "Tags:", comment: "Find Files: field label.")), tagField],
            [label(String(localized: "Kind:", comment: "Find Files: field label.")), kindPopup],
            [label(String(localized: "Size:", comment: "Find Files: field label.")), sizePopup],
            [label(String(localized: "Modified:", comment: "Find Files: field label.")), datePopup],
            [label(String(localized: "Search in:", comment: "Find Files: field label.")), scopePopup]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
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
        footer.widthAnchor.constraint(equalToConstant: 420).isActive = true
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
        onSearch?(query, scopePopup.indexOfSelectedItem == 0)
        dismiss(sender)
    }

    // MARK: - Query

    private func currentQuery() -> SpotlightQuery {
        let kind = kindOptions[max(0, kindPopup.indexOfSelectedItem)].kind
        return SpotlightQuery(
            nameContains: nameField.stringValue,
            contentContains: contentField.stringValue,
            kinds: kind.map { [$0] } ?? [],
            minSizeBytes: sizeOptions[max(0, sizePopup.indexOfSelectedItem)].bytes,
            modifiedWithin: dateOptions[max(0, datePopup.indexOfSelectedItem)].age,
            tags: enteredTags
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
        field.placeholderString = placeholder
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
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
