import AppKit
import DirnexCore

/// How the sidebar's flat row list is assembled from its sections, and how a section folds
/// (PLAN.md §M8 "Collapsible sections"). Split out of `SidebarViewController` for the same reason
/// the other sections are: that file rides its 500-line ceiling.
///
/// The list is an `NSTableView`, not an `NSOutlineView`, because every row it shows is a leaf —
/// nothing here nests, and an outline view would buy one level of disclosure at the price of a
/// second data-source shape for the drag code to map through. Folding is therefore not a view
/// feature but a build-time one: a collapsed section simply contributes its header and no items.
extension SidebarViewController {
    /// Append a section's header and, unless the user has folded it, its rows.
    ///
    /// An empty section is skipped entirely — header included — except where `showsEmptyHeader`
    /// says otherwise, which today is Favorites alone: that header is the drop target for dragging
    /// a folder in, so hiding it would hide the way back from having removed everything.
    func append(
        _ section: SidebarSection,
        items: [Row],
        showsEmptyHeader: Bool = false,
        to rows: inout [Row]
    ) {
        guard !items.isEmpty || showsEmptyHeader else { return }
        rows.append(.header(section))
        guard !sectionCollapse.isCollapsed(section) else { return }
        rows.append(contentsOf: items)
    }

    /// The row index of a section's header, or `nil` when the section isn't on screen.
    func headerRow(of section: SidebarSection) -> Int? {
        rows.firstIndex { $0.section == section }
    }

    // MARK: - Folding

    /// Fold or unfold the section whose header was clicked.
    ///
    /// Keyboard focus goes back to the active file pane exactly as an empty-space click does. A
    /// header is not a destination, and letting the source list take first responder here would
    /// silently kill the pane's F5/F6/F8 dispatch (see `SidebarTableView`).
    func toggleSection(atRow row: Int) {
        defer { delegate?.sidebarDidClickEmptyArea(self) }
        guard rows.indices.contains(row), let section = rows[row].section else { return }
        var collapse = sectionCollapse
        collapse.toggle(section)
        SidebarSectionCollapseStore.save(collapse)
    }

    /// Unfold a section, returning whether that changed anything.
    ///
    /// The drop path needs this: a folder dragged onto a folded Favorites header would otherwise be
    /// pinned into rows the user cannot see, which reads as the drop having done nothing.
    @discardableResult
    func expandSection(_ section: SidebarSection) -> Bool {
        var collapse = sectionCollapse
        guard collapse.setCollapsed(false, for: section) else { return false }
        SidebarSectionCollapseStore.save(collapse)
        return true
    }

    /// Rebuild when the fold state changes — here or in another window, since one collapse state is
    /// shared by every sidebar.
    func observeSectionCollapseChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sectionCollapseChanged),
            name: SidebarSectionCollapseStore.didChangeNotification,
            object: nil
        )
    }

    @objc func sectionCollapseChanged() {
        rebuild()
    }
}
