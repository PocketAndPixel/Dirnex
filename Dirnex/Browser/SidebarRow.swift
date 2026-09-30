import DirnexCore

/// One rendered sidebar row. Split out of `SidebarViewController` so that file stays under its
/// length limit — the same reason Favorites, Volumes, Recents and the Cloud section live beside
/// it.
extension SidebarViewController {
    /// A destination, or one of the three pieces of chrome around them. `internal` (not `private`)
    /// so the saved-search and server management extensions in companion files can read the clicked
    /// row.
    ///
    /// **The destinations are `SidebarPlace`, not cases of their own** (PLAN.md §M20). This enum used
    /// to spell out all ten — favorite, volume, vault, server, tag, iCloud, cloud mount, saved
    /// search, Recents, Trash — which made the sidebar the only surface that could name a place, and
    /// made a second renderer beside it a second copy of that vocabulary. Everything here is now what
    /// a *table* adds on top of the shared list: a header to fold under, blank padding, and the
    /// disclosure row that reveals the tags past the stock seven.
    enum Row {
        /// A destination. What it does when picked is `SidebarViewController.activate(_:)`'s, which
        /// the Go ▸ Places menu dispatches through as well, so a row and a menu item can never
        /// disagree about what a place means.
        case place(SidebarPlace)
        /// A section header. Carries the section's *identity*, not its title — the drag code used
        /// to find Favorites by comparing header text, which made a user-visible string
        /// load-bearing, and the fold state keys off the same case (PLAN.md §M8).
        case header(SidebarSection)
        /// Blank vertical space, carrying no content and no behavior — the one row that exists for
        /// layout alone. It sits above the headerless Trash row so that row reads as its own thing
        /// rather than as the last entry of whatever section happens to precede it (with Tags shown,
        /// Trash otherwise looks like an eighth tag color).
        ///
        /// A row rather than extra height on Trash itself, because `NSTableRowView` draws the
        /// selection across its **whole** height — measured: a 40 pt row gets a 40 pt capsule — so a
        /// padded Trash row would carry a visibly fatter highlight than every other row. It is
        /// unselectable, undraggable, has no menu and no path, and `SidebarTableView` treats a click
        /// on it as a click on empty space.
        case spacer
        /// The "All Tags…" row: reveals the tags found by browsing, past the stock seven.
        ///
        /// Chrome rather than a place, and deliberately so: it is a disclosure affordance belonging
        /// to a *scrolling list*, which is why the Places menu — where there is no such pressure —
        /// has no equivalent and simply lists every tag.
        case allTags

        var isHeader: Bool {
            section != nil
        }

        /// The section this row heads, when it is a header. Item rows return `nil` — they belong to
        /// a section but do not identify one, and the fold code only ever asks about headers.
        var section: SidebarSection? {
            if case let .header(section) = self { return section }
            return nil
        }

        /// The destination this row carries, when it is one.
        var place: SidebarPlace? {
            if case let .place(place) = self { return place }
            return nil
        }

        /// The directory behind the row, for the four places that are one. `nil` for the chrome and
        /// for every place that runs a query, connects or unlocks instead — see `SidebarPlace.path`,
        /// which is where that distinction is defined and tested.
        var path: VFSPath? {
            place?.path
        }

        var favorite: FavoriteEntry? {
            if case let .place(.favorite(entry)) = self { return entry }
            return nil
        }

        var savedSearch: SavedSearch? {
            if case let .place(.savedSearch(search)) = self { return search }
            return nil
        }

        var server: ServerConnection? {
            if case let .place(.server(connection)) = self { return connection }
            return nil
        }

        var vault: VaultLocation? {
            if case let .place(.vault(location)) = self { return location }
            return nil
        }

        var tag: FinderTag? {
            if case let .place(.tag(tag)) = self { return tag }
            return nil
        }
    }
}
