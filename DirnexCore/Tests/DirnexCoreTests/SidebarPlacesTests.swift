import Foundation
import Testing

@testable import DirnexCore

@Suite("Sidebar places")
struct SidebarPlacesTests {
    // MARK: - Fixtures

    private let search = SavedSearch(name: "All PDFs", query: FileQuery(nameContains: "pdf"))
    private let favorite = FavoriteEntry(path: .local("/Users/oleg/Dev"))
    private let iCloud = SidebarPlace.iCloudDrive(
        .local("/Users/oleg/Library/Mobile Documents/com~apple~CloudDocs")
    )
    private let mount = SidebarPlace.cloudMount(
        CloudStorageMount(
            directoryName: "GoogleDrive-someone@gmail.com",
            providerID: "GoogleDrive",
            accountLabel: "someone@gmail.com",
            name: "Google Drive",
            path: .local("/Users/oleg/Library/CloudStorage/GoogleDrive-someone@gmail.com")
        )
    )
    private let vault = VaultLocation(
        imagePath: "/Users/oleg/SecDocs.sparsebundle",
        volumeName: "SecDocs"
    )
    private let server = ServerConnection(
        name: "NAS",
        endpoint: .sftp(
            location: SFTPLocation(host: "nas.local", username: "sa"),
            authentication: .password
        )
    )
    private let tag = FinderTag(name: "Red", color: .red)

    private var volume: MountedVolume {
        MountedVolume(
            name: "Macintosh HD",
            path: .local("/"),
            isRoot: true,
            isRemovable: false,
            isEjectable: false,
            isInternal: true,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
    }

    /// Everything present, which is the arrangement every ordering claim below is made against.
    private func fullGroups() -> [SidebarPlaceGroup] {
        SidebarPlaces.groups(
            from: SidebarPlaceSources(
                searches: [search],
                favorites: [favorite],
                cloud: [iCloud, mount],
                volumes: [volume],
                vaults: [vault],
                servers: [server],
                tags: [tag]
            )
        )
    }

    private func empty() -> [SidebarPlaceGroup] {
        SidebarPlaces.groups(from: SidebarPlaceSources())
    }

    // MARK: - Order

    @Test("the sections come in SidebarSection.allCases order, between Recents and the Trash")
    func sectionOrder() {
        let sections = fullGroups().map(\.section)
        #expect(sections == [nil] + SidebarSection.allCases.map { $0 } + [nil])
    }

    @Test("Recents leads and the Trash closes, each alone in a headerless group")
    func headerlessSystemRows() {
        let groups = fullGroups()
        let first = groups.first
        let last = groups.last
        #expect(first?.section == nil)
        #expect(first?.places == [.recents])
        #expect(last?.section == nil)
        #expect(last?.places == [.trash])
    }

    // MARK: - Membership

    @Test("every place lands in its own section")
    func placesLandInTheirSection() {
        let groups = fullGroups()
        func places(of section: SidebarSection) -> [SidebarPlace] {
            groups.first { $0.section == section }?.places ?? []
        }
        #expect(places(of: .searches) == [.savedSearch(search)])
        #expect(places(of: .favorites) == [.favorite(favorite)])
        #expect(places(of: .icloud) == [iCloud, mount])
        #expect(places(of: .volumes) == [.volume(volume)])
        #expect(places(of: .vaults) == [.vault(vault)])
        #expect(places(of: .servers) == [.server(server)])
        #expect(places(of: .tags) == [.tag(tag)])
    }

    @Test("the Cloud section is passed through in the order it arrived, not re-sorted")
    func cloudOrderIsTheCallers() {
        // The user drags these rows and `CloudSectionOrderStore` remembers where they were put, so
        // the order is applied before assembly and must survive it untouched — including the case
        // where a mount has been dragged above iCloud Drive.
        let groups = SidebarPlaces.groups(from: SidebarPlaceSources(cloud: [mount, iCloud]))
        #expect(groups.first { $0.section == .icloud }?.places == [mount, iCloud])
    }

    // MARK: - Empty sections

    @Test("an empty section is dropped entirely")
    func emptySectionsAreDropped() {
        let sections = empty().compactMap(\.section)
        #expect(sections == [.favorites])
    }

    @Test("Favorites keeps its header when empty, because that header is the drop target")
    func favoritesSurvivesEmpty() {
        let favorites = empty().first { $0.section == .favorites }
        let hasFavorites = favorites != nil
        #expect(hasFavorites)
        #expect(favorites?.places.isEmpty == true)
    }

    @Test("Recents and the Trash are offered even when nothing else is")
    func systemRowsAreUnconditional() {
        let groups = empty()
        #expect(groups.first?.places == [.recents])
        #expect(groups.last?.places == [.trash])
    }

    // MARK: - Which places are a directory

    @Test("only the four places that are a directory report a path")
    func pathsAreOnlyForRealDirectories() {
        #expect(SidebarPlace.favorite(favorite).path == favorite.path)
        #expect(SidebarPlace.volume(volume).path == volume.path)
        #expect(iCloud.path != nil)
        #expect(mount.path != nil)
        // The other six run a query, connect, unlock or merge. A vault is the one worth stating
        // twice: it has a mount point once it is open, and it is `hdiutil`'s answer rather than
        // anything the place holds, so reporting one here would be a path that goes stale locked.
        for place in [
            SidebarPlace.recents,
            .trash,
            .savedSearch(search),
            .server(server),
            .tag(tag),
            .vault(vault)
        ] {
            #expect(place.path == nil)
        }
    }

    // MARK: - Folding is not an input

    @Test("a section holding places is always present — folding cannot reach this list")
    func foldingIsNotAnInput() {
        // The regression this pins is the reason M20's assembly is a separate function rather than
        // `SidebarViewController.rows`: a collapsed section contributes its header and *no items* to
        // the sidebar's row list, so a menu built from that list would lose whole sections for
        // anyone who folded one shut. There is no fold parameter here, and there must not be one —
        // what a disclosure triangle is doing is the table's business, not this list's.
        for group in fullGroups() where group.section != nil {
            let hasPlaces = !group.places.isEmpty
            #expect(hasPlaces, "\(String(describing: group.section)) came back empty")
        }
    }
}
