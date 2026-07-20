import AppKit
import DirnexCore

/// Keyboard access to the sidebar (PLAN.md §M8): focus the source list, move by row, fold sections,
/// and activate a row — all without the trackpad, in a keyboard-first app whose sidebar was
/// mouse-only until now. `SidebarTableView` intercepts the file-manager keys and forwards them here;
/// row movement (↑/↓) and type-select stay with `NSTableView`.
///
/// The model is `NSOutlineView`'s, adapted to a flat table whose "expand/collapse" is the M8 fold
/// state rather than a tree: ← collapses a header or steps out of an item to its header, → expands a
/// header or steps into it, Return activates an item or folds a header, and Tab/Escape leave for the
/// active pane. Headers are keyboard-selectable (`shouldSelectRow` returns true) precisely so ←/→
/// and Return have something to land on; the mouse still never selects one.
extension SidebarViewController {
    /// Wire the table's key callbacks to the handlers below. Called once from `loadView`.
    func registerKeyboardHandlers() {
        tableView.onActivateSelection = { [weak self] in self?.keyboardActivateSelection() }
        tableView.onMoveLeft = { [weak self] in self?.keyboardMoveLeft() }
        tableView.onMoveRight = { [weak self] in self?.keyboardMoveRight() }
        tableView.onReturnToPane = { [weak self] in self?.keyboardReturnToPane() }
    }

    /// Take keyboard focus (the entry point `view.focusSidebar` / ⌥⌘S reaches through the window
    /// controller, which reveals a collapsed sidebar first). The cursor lands on `path` if that
    /// place is pinned, else on the first real row — never on a header, so the first keystroke a
    /// user sees is a highlighted destination, not a section title.
    func focusFromKeyboard(preferring path: VFSPath?) {
        guard let window = view.window else { return }
        let target = path.flatMap { wanted in rows.firstIndex { $0.path == wanted } }
            ?? rows.firstIndex { !$0.isHeader }
        if let target { select(row: target) }
        window.makeFirstResponder(tableView)
    }

    // MARK: - Key handlers

    private func keyboardActivateSelection() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        if let section = rows[row].section {
            // A header activates by folding — Return is the keyboard twin of clicking it.
            foldFromKeyboard(section, collapsed: !sectionCollapse.isCollapsed(section))
        } else {
            // An item navigates the pane (or runs its query); `activate` hands focus back to the
            // pane on its own, so browsing continues there without another keystroke.
            activate(rowAt: row)
        }
    }

    private func keyboardMoveLeft() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }
        if let section = rows[row].section {
            // On a header: collapse it if open; an already-closed header has nowhere further left to
            // go, so it holds still rather than jumping to a neighbour.
            if !sectionCollapse.isCollapsed(section) {
                foldFromKeyboard(section, collapsed: true)
            }
        } else if let section = section(containingRow: row), let header = headerRow(of: section) {
            // On an item: step out to its section header, the way ← climbs to the parent in an
            // outline view.
            select(row: header)
        }
    }

    private func keyboardMoveRight() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row), let section = rows[row].section else { return }
        if sectionCollapse.isCollapsed(section) {
            foldFromKeyboard(section, collapsed: false)
        } else {
            // An open header steps into its first row; on an item → there is nothing further in to
            // go, so `keyDown`'s default (no-op) already covered it and this branch isn't reached.
            let next = row + 1
            if rows.indices.contains(next), !rows[next].isHeader { select(row: next) }
        }
    }

    private func keyboardReturnToPane() {
        // The window controller's empty-area handler focuses the active pane — the same exit a
        // header/empty click makes, reused so there is one way back.
        delegate?.sidebarDidClickEmptyArea(self)
    }

    // MARK: - Helpers

    /// Fold `section` and keep the cursor on its header with sidebar focus intact — the keyboard's
    /// counterpart to the mouse `toggleSection(atRow:)`, which instead hands focus back to the pane.
    /// The store write rebuilds the list synchronously (clearing selection), so the header is
    /// re-selected afterward against the fresh rows.
    private func foldFromKeyboard(_ section: SidebarSection, collapsed: Bool) {
        guard setSectionCollapsed(collapsed, for: section) else { return }
        if let header = headerRow(of: section) { select(row: header) }
        view.window?.makeFirstResponder(tableView)
    }

    private func select(row: Int) {
        guard rows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }
}
