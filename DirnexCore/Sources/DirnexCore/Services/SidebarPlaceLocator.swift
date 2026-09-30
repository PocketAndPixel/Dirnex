import Foundation

/// What a pane is showing, as far as the sidebar can tell which of its places that is.
///
/// A path alone is not enough: a results tab's path is synthetic (`search:/…`), and what makes it a
/// saved search's tab or a tag's is the query behind it. An archive's path names only its inside,
/// so the file it was opened from rides along too.
public struct SidebarPaneLocation: Equatable, Sendable {
    public var path: VFSPath
    /// The query behind a results tab, `nil` for anything else — Recents and the Trash included.
    public var searchQuery: FileQuery?
    /// That query's scope, `nil` for "everywhere".
    public var searchScope: VFSPath?
    /// The outermost archive file when the pane is inside an archive, so a folder that *holds* the
    /// archive can answer for it.
    public var archiveFile: VFSPath?

    public init(
        path: VFSPath,
        searchQuery: FileQuery? = nil,
        searchScope: VFSPath? = nil,
        archiveFile: VFSPath? = nil
    ) {
        self.path = path
        self.searchQuery = searchQuery
        self.searchScope = searchScope
        self.archiveFile = archiveFile
    }
}

/// Which sidebar place a pane is **in** — where View ▸ Focus Sidebar puts the cursor.
///
/// It used to be "the place whose path *is* the pane's", which almost nothing satisfies: a folder
/// one level inside Documents, iCloud Drive (whose listing is `icloud:/…` while its row names the
/// real container), a Photos month, a bucket, the Trash — every one of them matched no row, and the
/// cursor fell to the first row of the list, Recents. The rule now is the one the path bar already
/// draws: the place whose territory holds the location, and of several, the **deepest**. A folder in
/// `~/Dev/Common` is in Dev rather than Home, and Home rather than Macintosh HD.
///
/// A results tab has no territory, so it matches exactly or not at all: the Trash by its backend,
/// Recents by its listing name, a saved search and a tag by the query behind the tab.
///
/// Pure: the places arrive already assembled (``SidebarPlaces``), and the one fact they cannot
/// carry — where each unlocked vault is mounted — is handed in.
public enum SidebarPlaceLocator {
    /// The place `location` is in, or `nil` when none of `places` holds it. Of equally specific
    /// places, the first in `places` wins, which is sidebar order.
    ///
    /// `vaultMountPoints` maps a vault's ``VaultLocation/resolvedImagePath`` to where it is mounted;
    /// a locked vault is absent and holds nothing.
    public static func place(
        for location: SidebarPaneLocation,
        among places: [SidebarPlace],
        vaultMountPoints: [String: String] = [:]
    ) -> SidebarPlace? {
        if let place = best(among: places, scoring: {
            specificity(of: $0, for: location, vaultMountPoints: vaultMountPoints)
        }) {
            return place
        }
        // Inside an archive nothing but a pin *into* that archive can match the path itself, so the
        // question falls back to the file the archive was opened from.
        guard let archiveFile = location.archiveFile else { return nil }
        return best(among: places) {
            coverage(of: $0, for: archiveFile, vaultMountPoints: vaultMountPoints)
        }
    }

    /// The Recents listing's path: a results tab named by ``RecentsQuery/listingName``.
    public static var recentsPath: VFSPath {
        VFSPath(backend: .search, path: "/" + RecentsQuery.listingName)
    }

    /// A score for a place that *is* the tab rather than one containing it — above any depth.
    private static let exact = Int.max

    private static func best(
        among places: [SidebarPlace],
        scoring score: (SidebarPlace) -> Int?
    ) -> SidebarPlace? {
        var winner: (place: SidebarPlace, score: Int)?
        for place in places {
            guard let candidate = score(place), candidate > (winner?.score ?? Int.min) else { continue }
            winner = (place, candidate)
        }
        return winner?.place
    }

    /// How specifically `place` holds `location`, or `nil` when it does not.
    private static func specificity(
        of place: SidebarPlace,
        for location: SidebarPaneLocation,
        vaultMountPoints: [String: String]
    ) -> Int? {
        let path = location.path
        switch place {
        case .recents:
            return path == recentsPath && location.searchQuery == nil ? exact : nil
        case let .savedSearch(search):
            let matches = path.backend == .search
                && location.searchQuery == search.query
                && location.searchScope == search.scope
            return matches ? exact : nil
        case let .tag(tag):
            // The tag row's own query, spelled as `runTagSearch` spells it: by name, everywhere.
            let matches = path.backend == .search
                && location.searchQuery == FileQuery(tags: [tag.name])
                && location.searchScope == nil
            return matches ? exact : nil
        default:
            return coverage(of: place, for: path, vaultMountPoints: vaultMountPoints)
        }
    }

    /// How deep the territory of `place` that holds `path` is rooted — a count of the root's own
    /// path components plus one, so even `/` scores — or `nil` when `place` does not hold `path`.
    private static func coverage(
        of place: SidebarPlace,
        for path: VFSPath,
        vaultMountPoints: [String: String]
    ) -> Int? {
        territory(of: place, vaultMountPoints: vaultMountPoints)
            .filter { path.isSelfOrDescendant(of: $0) }
            .map { $0.ancestorsFromRoot.count }
            .max()
    }

    /// The subtrees `place` stands for.
    private static func territory(
        of place: SidebarPlace,
        vaultMountPoints: [String: String]
    ) -> [VFSPath] {
        switch place {
        case .recents, .savedSearch, .tag:
            return []
        case .trash:
            return [root(.trash)]
        case let .favorite(entry):
            return [entry.path]
        case let .iCloudDrive(container):
            // The merged listing, and every container beside CloudDocs: a folder opened from an
            // app's library is still iCloud Drive, as its path bar says.
            return [root(.icloud)] + (container.parent.map { [$0] } ?? [])
        case .photos:
            return [root(.photos)]
        case let .cloudMount(mount):
            // The mount, not `entryDirectory`: its root is a place too, above `My Drive`.
            return [mount.path]
        case let .volume(volume):
            return [volume.path]
        case let .vault(vault):
            return vaultMountPoints[vault.resolvedImagePath].map { [.local($0)] } ?? []
        case let .server(server):
            // `nil` for SMB, whose share is an ordinary volume and is found under Volumes.
            return server.endpoint.backendID.map { [root($0)] } ?? []
        }
    }

    private static func root(_ backend: VFSBackendID) -> VFSPath {
        VFSPath(backend: backend, path: "/")
    }
}
