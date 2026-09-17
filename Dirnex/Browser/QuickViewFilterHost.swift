import AppKit

/// A Quick View surface with a filter bar over it: the CSV table and the JSON tree, whose rows it
/// narrows (split out of `QuickViewTableView+Filter` when the tree gained a filter, 2026-09-15), and
/// the text preview, where it finds the text in place, joined later the same day by a rendered page
/// and a PDF, which find in place too (2026-09-17).
///
/// What the bar does is the same over all three and lives here once. View ▸ Filter (⌥⌘F) shows it with
/// the keyboard in its text and the text selected, so typing replaces it. While the keyboard is there:
/// - **Esc** clears the text, and a second Esc puts the bar away. The window's Quick View monitor
///   leaves Esc to any field being typed in, so the third, back in the file list, closes Quick View.
/// - **↑ / ↓** step through what the text found: the rows the filter left, the strip following, or
///   the matches in a text. The file list's arrows are its own again once the keyboard goes back to it.
/// - **Return** steps to the next match on a surface that *finds*, and ⇧Return to the previous one —
///   what every other find bar on the Mac does. On a surface that *narrows* (the table, the tree) it
///   hands the keyboard back instead, because there is nothing to step through that ↑ and ↓ are not
///   already stepping through: the rows are the result. It also hands the keyboard back on a find
///   surface with nothing to step to, so the key is never dead.
/// - **Tab** hands the keyboard back to the file list and keeps the filter, whichever the bar is doing.
///
/// What a filter matches, and what it does to the surface, is each surface's own (`filterChanged`).
@MainActor
protocol QuickViewFilterHost: NSView {
    var filterBar: QuickViewTableFilterBar { get }
    /// What the bar sits above and shortens: a scroll view for the rows and the text, the web view
    /// itself for a rendered page, the `PDFView` for a PDF. Only its top edge is the bar's business,
    /// which is why this is an `NSView` rather than the scroll view three of the five happen to have.
    var filterContentView: NSView { get }
    /// The content view's top edge: against the surface, or under the bar while it is shown.
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
    /// ↑ or ↓ in the text: move `step` results along what the filter found.
    func stepFilterResult(by step: Int)
    /// Whether Return steps through what the text found rather than handing the keyboard back.
    ///
    /// No default here on purpose, and each sub-protocol answers it — the shape `stepFilterResult`
    /// already has. A default in this extension *and* one in `QuickViewFindHost`'s would leave which
    /// is picked up to overload resolution at the point each conformance is declared, which is not a
    /// thing to leave to chance for a key's meaning.
    var returnStepsResults: Bool { get }
    /// Where the keyboard goes when the bar lets go of it with nobody to say where the file list is.
    var keyboardFallback: NSView { get }
}

/// A filter host whose results are rows: the table and the tree, where ↑ and ↓ move the selection.
@MainActor
protocol QuickViewRowFilterHost: QuickViewFilterHost {
    /// The table or outline whose rows the filter narrows.
    var filteredRowsView: NSTableView { get }
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
    ///
    /// `modifiers` is what tells ⇧Return from Return, and it is a *parameter* rather than a read of
    /// `NSEvent.modifierFlags` inside the rule — measured 2026-09-18, a field editor turns both into
    /// the same `insertNewline:`, and `insertLineBreak:` (the natural guess) is never sent, so the
    /// selector cannot carry the direction. Swift evaluates a default argument at each *call*, so the
    /// production callers read the live keyboard and a test can hand over `.shift` without one
    /// (docs/NOTES.md ▸ Testing, a rule whose input is read by the rule has one test case).
    func filterCommand(
        _ command: Selector,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) -> Bool {
        switch command {
        case #selector(NSResponder.cancelOperation(_:)):
            if filterBar.query.isEmpty {
                endFiltering()
            } else {
                filterBar.field.stringValue = ""
                filterChanged()
            }
        case #selector(NSResponder.insertNewline(_:)):
            if returnStepsResults {
                stepFilterResult(by: modifiers.contains(.shift) ? -1 : 1)
            } else {
                giveKeyboardBack()
            }
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            giveKeyboardBack()
        case #selector(NSResponder.moveUp(_:)):
            stepFilterResult(by: -1)
        case #selector(NSResponder.moveDown(_:)):
            stepFilterResult(by: 1)
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
        filterTopToBar = filterContentView.topAnchor.constraint(equalTo: filterBar.bottomAnchor)
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
        // One off before the other on, so the content is never pinned to both edges at once.
        if shown {
            filterTopToSurface?.isActive = false
            filterTopToBar?.isActive = true
        } else {
            filterTopToBar?.isActive = false
            filterTopToSurface?.isActive = true
        }
        needsLayout = true
    }

    /// Back to the file list, or — with nobody to say where that is — to the surface's own content,
    /// whose arrows the window's monitor hands on to the list in any case.
    func giveKeyboardBack() {
        if let returnKeyboard {
            returnKeyboard()
        } else {
            window?.makeFirstResponder(keyboardFallback)
        }
    }
}

extension QuickViewRowFilterHost {
    var keyboardFallback: NSView {
        filteredRowsView
    }

    /// Return hands the keyboard back here rather than stepping: the rows the filter left *are* the
    /// result, and ↑ and ↓ are already walking them, so a Return that stepped would be a second
    /// spelling of ↓ in place of the one key that leaves the bar.
    var returnStepsResults: Bool { false }

    func stepFilterResult(by step: Int) {
        stepSelection(by: step)
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
