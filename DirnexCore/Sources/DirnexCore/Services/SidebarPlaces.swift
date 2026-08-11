import Foundation

/// One destination the app offers — a folder to open, a query to run, a server to connect, a vault
/// to unlock (PLAN.md §M20).
///
/// This is the vocabulary the sidebar's rows and the Go ▸ Places menu **share**. Before M20 that
/// vocabulary lived only in `SidebarViewController.Row`, so the sidebar was the one surface that
/// could name a place; a second renderer built beside it would have re-derived which places exist,
/// what order they come in, and which of them are directories at all — and would have drifted, the
/// way every "one rule, two spellings" in docs/NOTES.md eventually does.
///
/// **Only four of the ten cases are a path**, which is the reason this is an enum rather than a list
/// of `VFSPath`s: a saved search and a tag run a *query*, a server *connects*, a vault *unlocks*,
/// iCloud Drive *merges* several containers into one listing, and Recents and the Trash are both
/// results panes rather than directories. What each one does when picked is the app's to dispatch
/// (`SidebarViewController.activate`); what it *is* is here.
public enum SidebarPlace: Equatable, Sendable {
    /// The recently-used-files query. Headerless and first, where Finder puts it.
    case recents
    /// Every volume's trash as one merged listing. Headerless and last, where the Dock puts it.
    case trash
    case savedSearch(SavedSearch)
    case favorite(FavoriteEntry)
    /// The user's iCloud Drive. Carries the container's path for identity, but opening it dispatches
    /// a *merge* of that container with the app libraries beside it (PLAN.md §M9) rather than a
    /// listing of the path itself.
    case iCloudDrive(VFSPath)
    /// One cloud provider's File Provider mount under `~/Library/CloudStorage` (PLAN.md §M10).
    case cloudMount(CloudStorageMount)
    case volume(MountedVolume)
    case vault(VaultLocation)
    case server(ServerConnection)
    case tag(FinderTag)

    /// The directory this place *is*, for the four that are one — and `nil` for the six that are
    /// not, which is the distinction the doc comment above is about.
    ///
    /// It is deliberately **not** "where activating this goes": iCloud Drive answers with its
    /// container while opening it assembles a merge (PLAN.md §M9), and a locked vault has no
    /// directory at all even though unlocking one lands somewhere. This is for the questions that
    /// are genuinely about a path — which row matches the pane's current location, what to show in
    /// a tooltip — and every caller that wants to *open* something goes through the dispatch funnel
    /// instead.
    public var path: VFSPath? {
        switch self {
        case .recents, .trash, .savedSearch, .server, .tag, .vault: nil
        case let .favorite(entry): entry.path
        case let .iCloudDrive(path): path
        case let .cloudMount(mount): mount.entryDirectory
        case let .volume(volume): volume.path
        }
    }
}

/// A section of the sidebar — or one of the two headerless system rows — together with what is in
/// it, in render order.
///
/// A `nil` section is the headerless case: Recents at the top and the Trash at the bottom sit
/// outside every collapsible section (see `SidebarSection`), and both faces of this list have to
/// render them somewhere, so they travel *in* the list rather than being remembered separately by
/// each renderer.
public struct SidebarPlaceGroup: Equatable, Sendable {
    public let section: SidebarSection?
    public let places: [SidebarPlace]

    public init(section: SidebarSection?, places: [SidebarPlace]) {
        self.section = section
        self.places = places
    }
}

/// Everything the assembly below arranges, as it comes out of the stores.
///
/// A value rather than seven arguments so that a section added later is a field with a default
/// rather than an edit at every call site — and so a test can name only the one section it is about.
/// Each field holds what belongs in its own section; that contract is the caller's to keep, exactly
/// as it was when the sidebar appended each section by hand.
public struct SidebarPlaceSources: Equatable, Sendable {
    public var searches: [SavedSearch]
    public var favorites: [FavoriteEntry]
    /// The Cloud section, **already in the user's order**: those rows are draggable and
    /// `CloudSectionOrderStore` remembers where they were put, which is app state this layer has no
    /// business reading. Carries `.iCloudDrive` and `.cloudMount` places.
    public var cloud: [SidebarPlace]
    public var volumes: [MountedVolume]
    public var vaults: [VaultLocation]
    public var servers: [ServerConnection]
    /// Every tag to offer. Empty when the user has turned tags off — that is a preference about the
    /// feature, so it withdraws the section here rather than being second-guessed downstream.
    public var tags: [FinderTag]

    public init(
        searches: [SavedSearch] = [],
        favorites: [FavoriteEntry] = [],
        cloud: [SidebarPlace] = [],
        volumes: [MountedVolume] = [],
        vaults: [VaultLocation] = [],
        servers: [ServerConnection] = [],
        tags: [FinderTag] = []
    ) {
        self.searches = searches
        self.favorites = favorites
        self.cloud = cloud
        self.volumes = volumes
        self.vaults = vaults
        self.servers = servers
        self.tags = tags
    }
}

/// The one assembly of every place the app can take you to, in the order it is shown (PLAN.md §M20).
///
/// Distinct from `SidebarLocations`, which *finds* the places on this Mac (which volumes are
/// mounted, whether there is an iCloud container): this *arranges* what was found, and does no I/O
/// at all. Every input arrives already loaded, so the whole thing is a pure function over the
/// stores' contents and is tested as one.
///
/// **Folding is not an input, deliberately.** Whether a section is collapsed is a state of the
/// sidebar's table — a disclosure triangle — and not a fact about which places exist. The sidebar
/// applies it while rendering these groups into rows; a menu built from this list must not, or a
/// user who folded Volumes shut to get some vertical room would silently lose Volumes from the menu
/// bar as well. That is exactly what building the menu from `SidebarViewController.rows` would have
/// done, since a collapsed section contributes its header and no items.
public enum SidebarPlaces {
    /// Assemble the full list. Sections come in `SidebarSection.allCases` order — the declaration
    /// order *is* the display order — so a section added later cannot be forgotten here: the switch
    /// below stops compiling until it is placed.
    public static func groups(from sources: SidebarPlaceSources) -> [SidebarPlaceGroup] {
        var groups = [SidebarPlaceGroup(section: nil, places: [.recents])]
        for section in SidebarSection.allCases {
            let places: [SidebarPlace] = switch section {
            case .searches: sources.searches.map(SidebarPlace.savedSearch)
            case .favorites: sources.favorites.map(SidebarPlace.favorite)
            case .icloud: sources.cloud
            case .volumes: sources.volumes.map(SidebarPlace.volume)
            case .vaults: sources.vaults.map(SidebarPlace.vault)
            case .servers: sources.servers.map(SidebarPlace.server)
            case .tags: sources.tags.map(SidebarPlace.tag)
            }
            guard !places.isEmpty || keepsHeaderWhenEmpty(section) else { continue }
            groups.append(SidebarPlaceGroup(section: section, places: places))
        }
        groups.append(SidebarPlaceGroup(section: nil, places: [.trash]))
        return groups
    }

    /// An empty section is dropped entirely — nobody wants a "Servers" header over nothing — except
    /// Favorites, whose header is the drop target for dragging a folder in. Hiding that one would
    /// hide the way back from having removed everything.
    private static func keepsHeaderWhenEmpty(_ section: SidebarSection) -> Bool {
        section == .favorites
    }
}
