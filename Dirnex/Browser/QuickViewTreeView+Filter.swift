import AppKit
import DirnexCore

/// Narrowing Quick View's tree to the values containing some text (2026-09-15; XML and property lists
/// from 2026-09-16).
///
/// View ▸ Filter (⌥⌘F) shows the CSV table's bar over the tree, its picker offering keys and values,
/// keys, or values — names rather than keys over XML — and its keys the table's
/// (`QuickViewFilterHost`). Which values match is `DirnexCore`'s (`TreeDocument.filter`), off the main
/// actor: measured in a release build, 1–5 ms over the 4 MB catalog in this repository for an ASCII
/// query, and 50–100 ms over it for one that is not, which decodes every text it reads.
///
/// The tree then lists the matches and the way down to each, and — the user's choice — a matched
/// object or array keeps everything inside it, closed. The whole document is searched, not only what
/// is open. It opens to show the matches while that stays within `filterRowBudget` rows, in one batch
/// of updates: opening rows one by one cost an outline view 62 ms a thousand and 1.3 s for twenty
/// thousand, and a batch a third to a ninth of that (measured). Clearing the text gives back the rows
/// that were open before the filter, with the selected value opened into view.
extension QuickViewTreeView: QuickViewFilterHost {
    var filteredRowsView: NSTableView { outlineView }

    var hasFilterableContent: Bool { document != nil }

    /// The most rows a filter opens the tree to. A branch past it stays closed and still lists only
    /// the way down to its matches when opened.
    static let filterRowBudget = 2000

    /// Run the filter the bar now describes. An empty text clears it at once; anything else is read
    /// off the main actor, and a filter still running for older text is stopped.
    func filterChanged() {
        filterGeneration += 1
        filterCancellation?.isCancelled = true
        filterCancellation = nil
        let query = filterBar.query
        guard let document, !query.isEmpty else {
            filterTask = nil
            applyFilter(nil, marking: nil)
            return
        }
        let generation = filterGeneration
        let scope = filterBar.scope
        let cancellation = CancellationFlag()
        filterCancellation = cancellation
        filterTask = Task { [weak self] in
            let found = await BlockingWork.run {
                document.filter(matching: query, in: scope) { cancellation.isCancelled }
            }
            guard let self, generation == filterGeneration, let found else { return }
            applyFilter(found, marking: (FilterQuery(query), scope))
        }
    }

    /// No filter, the bar away, and the keyboard back if it was in the bar — for a new document, which
    /// must not run a filter for the old one's text, and must not keep one still running.
    func resetFilter() {
        filterGeneration += 1
        filterCancellation?.isCancelled = true
        filterCancellation = nil
        filterTask = nil
        filter = nil
        filterMarking = nil
        filteredChildren = [:]
        expandedBeforeFilter = nil
        let hadKeyboard = filterHasKeyboard
        filterBar.field.stringValue = ""
        filterBar.showValueCount(matched: 0, of: 0, filtering: false)
        setFilterBarShown(false)
        if hadKeyboard { giveKeyboardBack() }
    }

    /// The children of `value` the filter leaves, worked out the first time the outline view asks,
    /// since it asks for them one index at a time.
    func shownChildren(of value: Int) -> [Int] {
        guard let document else { return [] }
        if let known = filteredChildren[value] { return known }
        let shown = document.children(of: value, filteredBy: filter)
        filteredChildren[value] = shown
        return shown
    }

    // MARK: - Private

    private func applyFilter(
        _ found: TreeFilter?,
        marking: (query: FilterQuery, scope: TreeFilterScope)?
    ) {
        guard let document else { return }
        filterBar.showValueCount(
            matched: found?.matchCount ?? 0,
            of: document.valueCount,
            filtering: found != nil
        )
        guard found != nil || filter != nil else { return }
        let selected = selectedValue
        if filter == nil {
            expandedBeforeFilter = openValues
        }
        filter = found
        filterMarking = found == nil ? nil : marking
        filteredChildren = [:]
        topLevel = document.topLevelValues(filteredBy: found)
        outlineView.collapseItem(nil, collapseChildren: true)
        outlineView.reloadData()
        let opening = found.map {
            document.initialExpansion(rowBudget: Self.filterRowBudget, filteredBy: $0)
        } ?? expandedBeforeFilter ?? []
        outlineView.beginUpdates()
        for value in opening {
            outlineView.expandItem(item(for: value))
        }
        outlineView.endUpdates()
        if found == nil {
            expandedBeforeFilter = nil
        }
        select(after: selected)
    }

    /// Every open container on screen, in row order, so that opening them again in this order opens
    /// each after its parent.
    private var openValues: [Int] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let item = outlineView.item(atRow: row) as? QuickViewTreeItem,
                  outlineView.isItemExpanded(item)
            else { return nil }
            return item.value
        }
    }

    /// Where the selection lands once the rows change. Filtered, it stays on a value that is itself a
    /// match, and otherwise goes to the first match on screen; cleared, it stays on the value it was on,
    /// opened into view.
    private func select(after previous: Int?) {
        var row = 0
        if let filter {
            if let previous, filter.isMatch(previous), rowOf(previous) >= 0 {
                row = rowOf(previous)
            } else if let first = (0..<outlineView.numberOfRows).first(where: { row in
                (outlineView.item(atRow: row) as? QuickViewTreeItem).map { filter.isMatch($0.value) }
                    ?? false
            }) {
                row = first
            }
        } else if let previous {
            row = max(reveal(previous), 0)
        }
        if outlineView.numberOfRows > 0 {
            let target = min(row, outlineView.numberOfRows - 1)
            outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
            outlineView.scrollRowToVisible(target)
        } else {
            outlineView.deselectAll(nil)
        }
        // Asked for directly: selecting the row index that was already selected posts no change,
        // though a different value may now sit on it.
        showSelectedValue()
    }

    private func rowOf(_ value: Int) -> Int {
        outlineView.row(forItem: item(for: value))
    }

    /// Open every container above `value` that is a row, top down, and answer its row, or -1.
    private func reveal(_ value: Int) -> Int {
        guard let document else { return -1 }
        var ancestors: [Int] = []
        var current = document.parent(of: value)
        while let parent = current {
            ancestors.append(parent)
            current = document.parent(of: parent)
        }
        for ancestor in ancestors.reversed() where rowOf(ancestor) >= 0 {
            outlineView.expandItem(item(for: ancestor))
        }
        return rowOf(value)
    }
}
