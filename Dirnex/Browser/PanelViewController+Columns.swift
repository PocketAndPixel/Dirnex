import AppKit
import DirnexCore

extension PanelViewController {
    /// A file-list column. Internal (not private) so the chrome/parent-row extensions
    /// in their own files can build cells and sort indicators for it.
    enum Column: String, CaseIterable {
        case name, size, date
        /// The ncdu-style size bar (PLAN.md §M6). Unlike the others it is *contextual*: it comes and
        /// goes with the mode — see `PanelViewController+SizeViz`.
        ///
        /// It is the only one left. Git's status used to be a contextual column beside it, following
        /// the *directory* rather than the tab; it is a badge in the name cell now (`GitBadgeView`),
        /// which is why the bookkeeping below still sums a footprint over a set of one.
        case sizeBar

        var title: String {
            switch self {
            case .name:
                return String(
                    localized: "Name",
                    comment: "File-list column header: the entry's name."
                )
            case .size:
                return String(
                    localized: "Size",
                    comment: "File-list column header: the file's size."
                )
            case .date:
                return String(
                    localized: "Date Modified",
                    comment: "File-list column header: last-modified date."
                )
            // Deliberately blank: the column is a picture of the Size column beside it, and a
            // second "Size" heading would read as a second quantity. Its tooltip names it.
            case .sizeBar: return ""
            }
        }

        /// Whether the column is only installed under some condition rather than always present.
        /// A permanently blank bar column in every pane not measuring one would be pure clutter, so
        /// it comes and goes with its mode.
        var isContextual: Bool {
            switch self {
            case .sizeBar: return true
            case .name, .size, .date: return false
            }
        }

        /// The sort this column's header applies, or `nil` when it isn't sortable.
        var sortKey: FileSort.Key? {
            switch self {
            case .name: return .name
            case .size: return .size
            case .date: return .modified
            // Not `nil` for want of a meaning — the bar *is* size, and clicking it plainly means
            // "sort by that". It routes to the same key the Size header does, so the two agree.
            case .sizeBar: return .size
            }
        }

        /// The width a fresh column opens at, and the narrowest the user can drag it —
        /// also the fallback layout for a tab that has no persisted columns.
        var defaultWidth: CGFloat {
            switch self {
            // Name flexes to fill the pane (`.firstColumnOnly` autoresizing), so this is
            // only its floor at first show; Size/Date are fixed and sized to their content.
            case .name: return 240
            case .size: return 90
            case .date: return 150
            // Was 120 pt — a track plus room for "100.0%" beside it. Now that the column defaults to
            // the bar alone (`SizeVizDisplayMode.bar`, which reserves no label), that width was mostly
            // empty, so it opens at 0.7 of it: 84 pt. The Percentage and Both modes still fit (the
            // number right-aligns, into the reserved slot in Both), and the user can drag it wider for
            // a longer bar. Deliberately not scaled below `minWidth`, which stays the floor for Both.
            case .sizeBar: return 84
            }
        }

        var minWidth: CGFloat {
            switch self {
            case .name: return 120
            case .size: return 60
            case .date: return 110
            // Below this the track is shorter than the label beside it and the bar stops being a
            // comparison at all.
            case .sizeBar: return 80
            }
        }
    }
}

/// Per-tab column widths and order (PLAN.md §M1 "column width/order per tab, persisted").
/// A pane has one `NSTableView` shared across its tabs, so switching tabs swaps the
/// table's column geometry in and out: the active tab's layout is applied on activation,
/// and the user's drags (resize/reorder) are captured back into it and persisted.
extension PanelViewController {
    /// The columns a tab with no stored layout falls back to — the declared order and
    /// default widths from `Column`. Contextual columns are excluded: they are not the user's to
    /// arrange, so they never appear in a stored layout (see `setSizeBarColumnInstalled`).
    static var defaultColumnLayout: [ColumnLayout] {
        Column.allCases
            .filter { !$0.isContextual }
            .map { ColumnLayout(id: $0.rawValue, width: Double($0.defaultWidth)) }
    }

    /// Start recording header drags. `NSTableView` posts these on the main thread as the
    /// user resizes or reorders a column; the guard skips the notifications our own
    /// `applyColumnLayout` provokes while it sets widths/order programmatically.
    func observeColumnLayoutChanges() {
        let center = NotificationCenter.default
        for name in [NSTableView.columnDidResizeNotification, NSTableView.columnDidMoveNotification] {
            center.addObserver(
                self,
                selector: #selector(columnLayoutChanged),
                name: name,
                object: tableView
            )
        }
    }

    @objc func columnLayoutChanged(_ notification: Notification) {
        guard isViewLoaded, !isApplyingColumnLayout else { return }
        let layout = currentColumnLayout
        // Window autoresizing can post a resize with no real change; only touch storage
        // (and disk) when the geometry actually moved.
        guard layout != tabs[activeTabIndex].columnLayout else { return }
        tabs[activeTabIndex].columnLayout = layout
        persistState()
    }

    /// Record the table's current column geometry into the active tab, so a later switch
    /// back to it — or a relaunch — restores exactly what the user last saw.
    func captureColumnLayout() {
        tabs[activeTabIndex].columnLayout = currentColumnLayout
    }

    /// The width every currently-installed contextual column has carved out of Name.
    ///
    /// Summed rather than asked of the one column there happens to be today, which is the bug the
    /// *second* contextual column introduced when the Git gutter still existed: written as a ternary
    /// it under-reclaimed by the bar's 137 pt whenever both were up, making Name ratchet narrower on
    /// every toggle of the mode inside a repository. Left as a sum now that Git's letter is a badge,
    /// because a set of one is exactly the shape that invites the ternary back.
    private var contextualColumnFootprint: Double {
        var total = 0.0
        if isSizeBarColumnInstalled { total += Double(sizeBarColumnFootprint) }
        return total
    }

    /// The table's live column geometry, in display order — recorded as it would be with **no**
    /// contextual column present, which is the only form a stored layout ever takes.
    ///
    /// Two things follow from that. The contextual columns themselves are left out: recording them
    /// would make an otherwise identical layout differ between a pane measuring sizes and one that
    /// isn't, and each crossing would rewrite the tab's stored columns for no user-visible reason.
    /// And the Name column gets their footprint added back, because while they are installed Name is
    /// physically that much narrower (`setSizeBarColumnInstalled` charges it there) — storing the
    /// carved width would make Name ratchet narrower on every trip through the mode.
    private var currentColumnLayout: [ColumnLayout] {
        let reclaimed = contextualColumnFootprint
        return tableView.tableColumns.compactMap {
            guard let column = Column(rawValue: $0.identifier.rawValue), !column.isContextual else {
                return nil
            }
            let width = Double($0.width) + (column == .name ? reclaimed : 0)
            return ColumnLayout(id: $0.identifier.rawValue, width: width)
        }
    }

    /// Apply `tab`'s stored layout (or the defaults when it has none) to the shared table.
    /// Reorders the known columns into the stored order, then sets each width; columns not
    /// named in the layout keep their relative position at the end. Guarded so the
    /// resulting resize/move notifications aren't captured straight back.
    func applyColumnLayout(for tab: PanelTab) {
        let layout = tab.columnLayout ?? PanelViewController.defaultColumnLayout
        isApplyingColumnLayout = true
        defer {
            isApplyingColumnLayout = false
            // Re-attach the contextual columns for the tab being switched to, after the layout pass:
            // they are absent from every stored layout, so the reordering below would otherwise
            // shuffle them to the far end of the table, one column at a time.
            updateSizeBarColumn()
        }
        setSizeBarColumnInstalled(false)

        var targetIndex = 0
        for item in layout {
            let identifier = NSUserInterfaceItemIdentifier(item.id)
            let current = tableView.column(withIdentifier: identifier)
            // A column that no longer exists (e.g. a layout from a future build) is skipped.
            guard current >= 0 else { continue }
            if current != targetIndex {
                tableView.moveColumn(current, toColumn: targetIndex)
            }
            tableView.tableColumns[targetIndex].width = CGFloat(item.width)
            targetIndex += 1
        }
    }

    /// Widen or narrow the Name column by `delta`, to make room for a contextual column or reclaim
    /// it. `NSTableColumn` clamps to its own `minWidth`, so a pane already squeezed to the floor
    /// keeps a legible name and lets the Size/Date pair shift instead — the lesser of the two evils,
    /// and only at widths where nothing readable was on offer anyway.
    ///
    /// A contextual column is **paid for out of Name**, never added on top of the table: appending
    /// its width to the total would push Size and Date sideways every time it came or went, moving
    /// columns the user had placed deliberately for a reason that has nothing to do with them. Name
    /// is the right column to charge because it is already the one that absorbs slack
    /// (`firstColumnOnlyAutoresizingStyle`) — it is the flexible one by design, and a filename with
    /// less room is a truncation, not a rearranged pane.
    func resizeNameColumn(by delta: CGFloat) {
        let identifier = NSUserInterfaceItemIdentifier(Column.name.rawValue)
        let index = tableView.column(withIdentifier: identifier)
        guard index >= 0 else { return }
        let column = tableView.tableColumns[index]
        column.width += delta
    }
}
