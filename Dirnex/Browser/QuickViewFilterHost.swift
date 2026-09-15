import AppKit

/// A Quick View surface with a filter bar over its rows: the CSV table and the JSON tree (split out of
/// `QuickViewTableView+Filter` when the tree gained a filter, 2026-09-15).
///
/// What the bar does is the same over both and lives here once. View ▸ Filter (⌥⌘F) shows it with the
/// keyboard in its text and the text selected, so typing replaces it. While the keyboard is there:
/// - **Esc** clears the text, and a second Esc puts the bar away. The window's Quick View monitor
///   leaves Esc to any field being typed in, so the third, back in the file list, closes Quick View.
/// - **↑ / ↓** step through the rows the filter left, the strip following. The file list's arrows
///   are its own again once the keyboard goes back to it.
/// - **Return** and **Tab** hand the keyboard back to the file list and keep the filter.
///
/// What a filter matches, and what it does to the rows, is each surface's own (`filterChanged`).
@MainActor
protocol QuickViewFilterHost: NSView {
    var filterBar: QuickViewTableFilterBar { get }
    var scrollView: NSScrollView { get }
    /// The table or outline whose rows the filter narrows.
    var filteredRowsView: NSTableView { get }
    /// The scroll view's top edge: against the surface, or under the bar while it is shown.
    var filterTopToSurface: NSLayoutConstraint? { get set }
    var filterTopToBar: NSLayoutConstraint? { get set }
    /// Where the keyboard goes when the bar lets go of it: the file list the arrows walk. Set by
    /// whoever opens the bar, since the surface does not know which list that is.
    var returnKeyboard: (() -> Void)? { get set }
    /// The last filter sent off the main actor — what a test awaits to know it has landed.
    var filterTask: Task<Void, Never>? { get }
    /// Whether there is anything on the surface to filter.
    var hasFilterableContent: Bool { get }
    /// Run the filter the bar now describes.
    func filterChanged()
}

extension QuickViewFilterHost {
    /// Show the bar if it is not up, with the keyboard in its text and the text selected, so typing
    /// replaces it. Does nothing with nothing on the surface to filter.
    func beginFiltering() {
        guard hasFilterableContent else { return }
        setFilterBarShown(true)
        window?.makeFirstResponder(filterBar.field)
        filterBar.field.currentEditor()?.selectAll(nil)
    }

    /// Put the bar away with every row back, and hand the keyboard back if it was in the bar.
    func endFiltering() {
        let hadKeyboard = filterHasKeyboard
        filterBar.field.stringValue = ""
        filterChanged()
        setFilterBarShown(false)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// Whether the keyboard is in the filter's text: its field editor is first responder.
    var filterHasKeyboard: Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else {
            return false
        }
        return (editor.delegate as? NSView) === filterBar.field
    }

    /// What a key the field editor was about to act on does instead (see the protocol's comment).
    func filterCommand(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            if filterBar.query.isEmpty {
                endFiltering()
            } else {
                filterBar.field.stringValue = ""
                filterChanged()
            }
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            giveKeyboardBack()
        case #selector(NSResponder.moveUp(_:)):
            stepSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            stepSelection(by: 1)
        default:
            return false
        }
        return true
    }

    /// The height the rows and the strip share: the surface's, less the bar's while it is shown.
    var roomBelowFilterBar: CGFloat {
        bounds.height - (filterBar.isHidden ? 0 : QuickViewTableFilterBar.height)
    }

    func installFilterBar() {
        filterBar.isHidden = true
        addSubview(filterBar)
        filterTopToBar = scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)
        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: topAnchor)
        ])
        filterBar.changed = { [weak self] in self?.filterChanged() }
        filterBar.command = { [weak self] command in self?.filterCommand(command) ?? false }
        filterBar.close = { [weak self] in self?.endFiltering() }
    }

    func setFilterBarShown(_ shown: Bool) {
        guard filterBar.isHidden == shown else { return }
        filterBar.isHidden = !shown
        // One off before the other on, so the scroll view is never pinned to both edges at once.
        if shown {
            filterTopToSurface?.isActive = false
            filterTopToBar?.isActive = true
        } else {
            filterTopToBar?.isActive = false
            filterTopToSurface?.isActive = true
        }
        needsLayout = true
    }

    /// Back to the file list, or — with nobody to say where that is — to the rows, whose arrows the
    /// window's monitor hands on to the list in any case.
    func giveKeyboardBack() {
        if let returnKeyboard {
            returnKeyboard()
        } else {
            window?.makeFirstResponder(filteredRowsView)
        }
    }

    /// Select the row `step` rows from the selection, within the rows drawn: from the last selected
    /// going down, the first going up, and from the top or the bottom when nothing is selected.
    func stepSelection(by step: Int) {
        let count = filteredRowsView.numberOfRows
        guard count > 0 else { return }
        let selected = filteredRowsView.selectedRowIndexes
        let from = step > 0 ? selected.last : selected.first
        let target = from.map { $0 + step } ?? (step > 0 ? 0 : count - 1)
        let row = min(max(target, 0), count - 1)
        filteredRowsView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        filteredRowsView.scrollRowToVisible(row)
    }
}
