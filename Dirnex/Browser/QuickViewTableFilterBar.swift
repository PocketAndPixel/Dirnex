import AppKit
import DirnexCore

/// The bar over Quick View's table or tree that narrows it to what contains some text (2026-09-15): a
/// picker — a column for the table, keys or names or values for the tree — the text, how many rows or
/// values are left, and a button to put it away. Over a text preview it finds rather than narrows
/// (2026-09-17): no picker, and the count says which match is the current one (`useForFinding`).
///
/// The magnifying glass carries Case Sensitive and Whole Word, which every surface reads the same way
/// (`FilterQuery.Options`, 2026-09-18).
///
/// It reports and decides nothing. The surface runs the filter (`QuickViewTableView+Filter`,
/// `QuickViewTreeView+Filter`) and `QuickViewFilterHost` owns what each key does, so the bar can be
/// driven in a test without a window's key handling in the way.
@MainActor
final class QuickViewTableFilterBar: NSVisualEffectView, NSSearchFieldDelegate {
    static let height: CGFloat = 30

    /// The text or the column changed.
    var changed: () -> Void = {}
    /// A key the field editor would otherwise act on — Esc, Return, Tab, ↑ and ↓. `true` when handled.
    var command: (Selector) -> Bool = { _ in false }
    /// The close button.
    var close: () -> Void = {}

    let columnPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// `string:` because it is the initializer that scrolls a long value rather than clipping it
    /// (measured; docs/NOTES.md ▸ AppKit on text fields).
    let field = NSSearchField(string: "")
    let countLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()

    /// The tag of the picker's first item, which searches every column.
    private static let allColumnsTag = -1

    /// Where Case Sensitive and Whole Word live — one object shared with every other bar in the app,
    /// so an option turned on over a text preview is already on over the next CSV, and is still on at
    /// the next launch. Required, never defaulted: see the store's own note on the test target's
    /// `UserDefaults.standard`.
    let findOptions: QuickViewFindOptionsStore

    init(findOptions: QuickViewFindOptionsStore) {
        self.findOptions = findOptions
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .withinWindow
        // Active in a background window too, like the Quick View header: a bar that goes flat when
        // the window is not key reads as a control that stopped working.
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        build()
        // Selector-based, so it can be torn down from a `nonisolated deinit` — a token array is not
        // `Sendable` (docs/NOTES.md > Swift 6 and concurrency). Scoped to this store by `object:`, so
        // a bar on a test's scratch store never hears the app's.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(findOptionsChanged),
            name: QuickViewFindOptionsStore.didChange,
            object: findOptions
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The text being searched for.
    var query: String { field.stringValue }

    /// How the text is read: Case Sensitive and Whole Word, off unless the user turned one on.
    ///
    /// Read from the shared store rather than held here, so all five surfaces answer the same and a
    /// choice outlives both a new file and the app (2026-09-18). Nothing writes it but ``applyOptions``.
    var options: FilterQuery.Options { findOptions.options }

    /// The one way the options change — and it changes them for every bar, not this one.
    ///
    /// The store is what rebuilds this menu and re-runs this search, through the notification below,
    /// so the bar the user clicked takes exactly the path the other four take. One path rather than
    /// two is the point: a bar that updated itself directly *and* through the store would be the only
    /// one whose behaviour was never exercised by the ordinary case.
    func applyOptions(_ newValue: FilterQuery.Options) {
        findOptions.apply(newValue)
    }

    /// Another bar — or this one — changed the options. Rebuild the menu from the store (it is
    /// copied when displayed, so the state has to come from the value rather than from the item that
    /// was clicked) and search again under the new reading.
    @objc private func findOptionsChanged() {
        buildOptionsMenu()
        changed()
    }

    /// The column searched, or `nil` for every column.
    var column: Int? {
        let tag = columnPicker.selectedTag()
        return tag == Self.allColumnsTag ? nil : tag
    }

    /// The part of a value searched — the tree's picker.
    var scope: TreeFilterScope {
        TreeFilterScope(rawValue: columnPicker.selectedTag()) ?? .keysAndValues
    }

    /// Offer keys and values, keys, or values as what to search, the first chosen — the tree's picker.
    /// Over XML the first column holds names, and the picker says so.
    func setScopes(naming noun: TreeLabelNoun = .key) {
        columnPicker.removeAllItems()
        let choices = [
            (TreeFilterScope.keysAndValues, noun == .key ? String(
                localized: "Keys and Values",
                comment: "Quick View JSON tree filter: the picker’s item that searches both keys and values."
            ) : String(
                localized: "Names and Values",
                comment: """
                Quick View XML tree filter: the picker’s item that searches both the names of elements and \
                attributes and their values.
                """
            )),
            (.keys, noun == .key ? String(
                localized: "Keys",
                comment: "Quick View JSON tree filter: the picker’s item that searches only keys."
            ) : String(
                localized: "Names",
                comment: """
                Quick View XML tree filter: the picker’s item that searches only the names of elements and \
                attributes.
                """
            )),
            (.values, String(
                localized: "Values",
                comment: "Quick View JSON tree filter: the picker’s item that searches only values."
            ))
        ]
        for (scope, title) in choices {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = scope.rawValue
            columnPicker.menu?.addItem(item)
            if scope == .keysAndValues {
                columnPicker.menu?.addItem(.separator())
            }
        }
        columnPicker.selectItem(withTag: TreeFilterScope.keysAndValues.rawValue)
        columnPicker.setAccessibilityLabel(String(
            localized: "What to Filter",
            comment: "Quick View JSON tree filter: accessibility label of the keys-or-values picker."
        ))
    }

    /// "12 of 3000 values", or nothing while no text is typed — the tree's count, of the values that
    /// matched rather than the rows shown, since a matched container shows everything it holds.
    func showValueCount(matched: Int, of total: Int, filtering: Bool) {
        countLabel.stringValue = filtering ? String(
            localized: "\(matched) of \(total) values",
            comment: """
            Quick View JSON tree filter: how many values matched. %1$lld values matched, of %2$lld in \
            the file. Plural on the second.
            """
        ) : ""
    }

    /// Offer `titles` as the columns to search, every column chosen.
    func setColumns(_ titles: [String]) {
        columnPicker.setAccessibilityLabel(String(
            localized: "Column to Filter",
            comment: "Quick View table filter: accessibility label of the column picker."
        ))
        columnPicker.removeAllItems()
        columnPicker.addItem(withTitle: String(
            localized: "All Columns",
            comment: "Quick View table filter: the column picker’s item that searches every column."
        ))
        columnPicker.lastItem?.tag = Self.allColumnsTag
        guard !titles.isEmpty else { return }
        columnPicker.menu?.addItem(.separator())
        for (index, title) in titles.enumerated() {
            // Added as an item rather than by title, since `addItem(withTitle:)` replaces an item of
            // the same name, and two columns may share one.
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.tag = index
            columnPicker.menu?.addItem(item)
        }
        columnPicker.selectItem(withTag: Self.allColumnsTag)
    }

    /// Set the bar up to find in a text: nothing to pick, and the field and close button named for
    /// finding.
    func useForFinding() {
        columnPicker.isHidden = true
        field.placeholderString = String(
            localized: "Find in Text",
            comment: "Quick View text find: placeholder of the text field."
        )
        let closeTitle = String(
            localized: "Close Find Bar",
            comment: "Quick View text find: tooltip and accessibility label of the close button."
        )
        closeButton.toolTip = closeTitle
        closeButton.image?.accessibilityDescription = closeTitle
        closeButton.setAccessibilityLabel(closeTitle)
    }

    /// "3 of 17 matches", "3 of 100 000+ matches" when the search stopped at its limit, "No matches",
    /// or nothing while no text is typed. `current` counts from 1.
    func showMatchCount(current: Int, of total: Int, isComplete: Bool, finding: Bool) {
        guard finding else {
            countLabel.stringValue = ""
            return
        }
        guard total > 0 else {
            countLabel.stringValue = String(
                localized: "No matches",
                comment: "Quick View text find: the count when the text is found nowhere in the file."
            )
            return
        }
        countLabel.stringValue = isComplete ? String(
            localized: "\(current) of \(total) matches",
            comment: """
            Quick View text find: which match is the current one. %1$lld is the current match, of \
            %2$lld in the file. Plural on the second.
            """
        ) : String(
            localized: "\(current) of \(total)+ matches",
            comment: """
            Quick View text find: which match is the current one, when the search stopped at its limit \
            with more in the file. %1$lld is the current match, of more than %2$lld. Plural on the second.
            """
        )
    }

    /// "12 of 3000 rows", or nothing while no text is typed.
    func showCount(shown: Int, of total: Int, filtering: Bool) {
        countLabel.stringValue = filtering ? String(
            localized: "\(shown) of \(total) rows",
            comment: """
            Quick View table filter: how many rows the filter left. %1$lld rows are shown, of %2$lld in \
            the file. Plural on the second.
            """
        ) : ""
    }

    // MARK: - Field

    func controlTextDidChange(_ notification: Notification) {
        changed()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        command(commandSelector)
    }

    @objc private func columnChosen(_ sender: NSPopUpButton) {
        changed()
    }

    @objc private func closeClicked(_ sender: NSButton) {
        close()
    }

    private func build() {
        columnPicker.controlSize = .small
        columnPicker.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        columnPicker.target = self
        columnPicker.action = #selector(columnChosen(_:))
        setColumns([])

        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.placeholderString = String(
            localized: "Filter Rows",
            comment: "Quick View table filter: placeholder of the text field."
        )
        field.delegate = self
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buildOptionsMenu()

        countLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let closeTitle = String(
            localized: "Close Filter",
            comment: "Quick View table filter: tooltip and accessibility label of the close button."
        )
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: closeTitle)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = closeTitle
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [columnPicker, field, countLabel, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(separator)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A long column name gives way before the text does.
            columnPicker.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
