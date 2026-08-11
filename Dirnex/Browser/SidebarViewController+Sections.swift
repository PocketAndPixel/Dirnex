import AppKit
import DirnexCore

/// How the sidebar's flat row list is assembled from `SidebarPlaces`, and how a section folds
/// (PLAN.md §M8 "Collapsible sections", §M20). Split out of `SidebarViewController` for the same
/// reason the other sections are: that file rides its 500-line ceiling.
///
/// The list is an `NSTableView`, not an `NSOutlineView`, because every row it shows is a leaf —
/// nothing here nests, and an outline view would buy one level of disclosure at the price of a
/// second data-source shape for the drag code to map through. Folding is therefore not a view
/// feature but a build-time one: a collapsed section simply contributes its header and no items.
extension SidebarViewController {
    // MARK: - Sources

    /// Read every store the sidebar draws from, in one place, and hand the result to the shared
    /// assembly. The Go ▸ Places menu reads the same function, which is what makes "the menu shows
    /// what the sidebar shows" true by construction rather than by two lists agreeing.
    ///
    /// Not pure, deliberately: it touches seven `UserDefaults`-backed stores and enumerates the
    /// mounted volumes, which is exactly the I/O `SidebarPlaces` refuses to do. It also refreshes
    /// `vaultMountPoints` as a side effect, because that answer is needed *before* the Volumes
    /// section is assembled — see below.
    func placeSources() -> SidebarPlaceSources {
        // Vaults are resolved first because a vault's own volume must never *also* appear under
        // Volumes: a row that moved between sections as it was unlocked would be the one place the
        // user goes to unlock it, and the duplicate carries a plain eject button that detaches the
        // image without any of the bookkeeping Lock does (evicting the panes standing inside it, and
        // dropping what `VaultPrivacy` must forget).
        //
        // `-nobrowse` used to make that impossible by itself — a hidden volume is skipped by
        // `mountedVolumeURLs(options: [.skipHiddenVolumes])` — so this was once true by construction
        // and is now a rule that has to be kept: a vault with `showsInFinder` on is browsable, and
        // is enumerated here exactly like any other mount (verified).
        let vaults = VaultStore.load().vaults
        vaultMountPoints = Self.mountPoints(of: vaults)
        return SidebarPlaceSources(
            searches: SavedSearchStore.load().searches,
            favorites: FavoritesStore.load().entries,
            cloud: cloudPlaces(),
            volumes: SidebarLocations.hidingVaults(
                in: SidebarLocations.volumes(),
                mountedAt: Set(vaultMountPoints.values)
            ),
            vaults: vaults,
            servers: ServerConnectionStore.load().connections,
            tags: offeredTags()
        )
    }

    // MARK: - Rendering

    /// Render one assembled group into table rows: a header, then its places unless the user has
    /// folded the section shut.
    ///
    /// **The fold is applied here and nowhere upstream**, which is the whole point of the split
    /// (PLAN.md §M20): a disclosure triangle is a fact about this table, so a section folded shut
    /// still reaches the menu bar in full.
    func render(_ group: SidebarPlaceGroup, into rows: inout [Row]) {
        guard let section = group.section else {
            renderHeaderless(group.places, into: &rows)
            return
        }
        rows.append(.header(section))
        guard !sectionCollapse.isCollapsed(section) else { return }
        rows.append(contentsOf: displayed(group.places, in: section).map(Row.place))
        // "All Tags…" only when there is something behind it. Finder can always offer it because it
        // knows every tag you own; we know the ones we have seen, so offering to reveal nothing
        // would be a row that does nothing when clicked — worse than no row.
        if section == .tags, !showsAllTags, group.places.count > FinderTag.systemTags.count {
            rows.append(.allTags)
        }
    }

    /// Recents (which leads the list, where Finder puts it) and the Trash (which closes it, where
    /// the Dock puts it) render bare, outside every collapsible section — a header to caption one
    /// fixed row is pure weight.
    ///
    /// The Trash takes a spacer first. Having no header of its own it would otherwise sit flush
    /// against the section above and read as a member of it — with Tags shown, as an eighth tag
    /// color — so the spacer restores the separation a header used to provide, at exactly the gap
    /// AppKit itself puts above a section (see `heightOfRow`).
    private func renderHeaderless(_ places: [SidebarPlace], into rows: inout [Row]) {
        for place in places {
            if case .trash = place { rows.append(.spacer) }
            rows.append(.place(place))
        }
    }

    /// What a section actually draws, which is everything it holds except in Tags: that one shows
    /// the stock seven until "All Tags…" is clicked, so the rest of the list is withheld from the
    /// *table* while remaining in the assembly every other surface reads.
    ///
    /// The stock seven come from `FinderTag.systemTags` rather than from the front of the list,
    /// because they are a constant that exists before anything has been scanned — which is what
    /// keeps the section from ever being empty-and-useless.
    private func displayed(_ places: [SidebarPlace], in section: SidebarSection) -> [SidebarPlace] {
        guard section == .tags, !showsAllTags else { return places }
        return FinderTag.systemTags.map(SidebarPlace.tag)
    }

    /// The row index of a section's header, or `nil` when the section isn't on screen.
    func headerRow(of section: SidebarSection) -> Int? {
        rows.firstIndex { $0.section == section }
    }

    /// The section a row belongs to: its own if the row is a header, otherwise the nearest header
    /// above it. Used by keyboard folding, where the cursor sits on an item but ←/→ act on the
    /// section around it.
    func section(containingRow row: Int) -> SidebarSection? {
        guard rows.indices.contains(row) else { return nil }
        // Recents and Trash are headerless system rows outside every section (see `SidebarSection`),
        // so ←/→ must not climb from them into whatever section happens to sit above or below —
        // Trash, at the very bottom, would otherwise resolve to the last section's header. The
        // spacer beside it is blank padding and belongs to nothing at all.
        switch rows[row] {
        case .place(.recents), .place(.trash), .spacer: return nil
        default: break
        }
        for index in stride(from: row, through: 0, by: -1) {
            if let section = rows[index].section { return section }
        }
        return nil
    }

    // MARK: - Folding

    /// Fold or unfold the section whose header was **clicked**.
    ///
    /// Keyboard focus goes back to the active file pane exactly as an empty-space click does. A
    /// header is not a destination, and letting the source list take first responder here would
    /// silently kill the pane's F5/F6/F8 dispatch (see `SidebarTableView`). The keyboard path folds
    /// through `setSectionCollapsed` directly instead, precisely because it must *keep* sidebar
    /// focus.
    func toggleSection(atRow row: Int) {
        defer { delegate?.sidebarDidClickEmptyArea(self) }
        guard rows.indices.contains(row), let section = rows[row].section else { return }
        setSectionCollapsed(!sectionCollapse.isCollapsed(section), for: section)
    }

    /// Set a section's fold state, persisting it (which rebuilds every open sidebar via the store's
    /// notification). Returns whether anything changed, so a caller can skip re-selecting or
    /// re-scrolling on a no-op. Focus-neutral: callers that need focus moved do it themselves.
    @discardableResult
    func setSectionCollapsed(_ collapsed: Bool, for section: SidebarSection) -> Bool {
        var collapse = sectionCollapse
        guard collapse.setCollapsed(collapsed, for: section) else { return false }
        SidebarSectionCollapseStore.save(collapse)
        return true
    }

    /// Unfold a section, returning whether that changed anything.
    ///
    /// The drop path needs this: a folder dragged onto a folded Favorites header would otherwise be
    /// pinned into rows the user cannot see, which reads as the drop having done nothing.
    @discardableResult
    func expandSection(_ section: SidebarSection) -> Bool {
        setSectionCollapsed(false, for: section)
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
