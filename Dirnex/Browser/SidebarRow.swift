import AppKit
import DirnexCore

/// One rendered sidebar row. Split out of `SidebarViewController` so that file stays under its
/// length limit — the same reason Favorites, Volumes, Recents and the Cloud section live beside
/// it.
extension SidebarViewController {
    /// A section header or a navigable destination. `internal` (not `private`) so the saved-search
    /// and server management extensions in companion files can read the clicked row.
    enum Row {
        /// The Trash row: a fixed system row that opens every volume's trash as one merged listing
        /// (PLAN.md §M8). Like `.recents` it carries nothing — the Trash is not one directory, so
        /// there is no path to hold.
        case trash
        /// A section header. Carries the section's *identity*, not its title — the drag code used
        /// to find Favorites by comparing header text, which made a user-visible string
        /// load-bearing, and the fold state keys off the same case (PLAN.md §M8).
        case header(SidebarSection)
        /// The Recents row: a fixed system row that runs the recently-used-files query into a virtual
        /// results panel (PLAN.md §M8). Carries nothing — like a saved search it dispatches a query,
        /// not a place, so it has no path and no stored model.
        case recents
        /// A pinned folder in the user-owned Favorites section — the favorites, which since M8 *is*
        /// this section rather than a separate popup (PLAN.md §M8).
        case favorite(FavoriteEntry)
        /// The user's iCloud Drive: a fixed system row in the Cloud section (PLAN.md §M8). Carries
        /// its path directly — it is one known location, not a stored model like a pin or a volume.
        case iCloud(VFSPath)
        /// One cloud provider's File Provider mount under `~/Library/CloudStorage` — Google Drive
        /// and anything installed beside it (PLAN.md §M10 Phase 1).
        ///
        /// Unlike `.iCloud`, which dispatches a merge, this navigates its path like a favorite or a
        /// volume does: the mount is an ordinary directory, which is the entire reason Phase 1
        /// needs no backend.
        case cloudMount(CloudStorageMount)
        case volume(MountedVolume)
        case savedSearch(SavedSearch)
        case server(ServerConnection)
        case tag(FinderTag)
        /// The "All Tags…" row: reveals the tags found by browsing, past the stock seven.
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

        /// The path a click navigates to, when the row is a real location. `nil` for headers, saved
        /// searches, servers, and tags — a saved search runs a query, a server connects/mounts, and
        /// a tag searches, so each is dispatched through its own delegate call instead of pointing
        /// at a directory.
        var path: VFSPath? {
            switch self {
            case .header, .recents, .trash, .savedSearch, .server, .tag, .allTags: return nil
            case let .favorite(entry): return entry.path
            case let .iCloud(path): return path
            case let .cloudMount(mount): return mount.path
            case let .volume(volume): return volume.path
            }
        }

        var favorite: FavoriteEntry? {
            if case let .favorite(entry) = self { return entry }
            return nil
        }

        var savedSearch: SavedSearch? {
            if case let .savedSearch(search) = self { return search }
            return nil
        }

        var server: ServerConnection? {
            if case let .server(connection) = self { return connection }
            return nil
        }

        var tag: FinderTag? {
            if case let .tag(tag) = self { return tag }
            return nil
        }
    }
}
