import Foundation
import Testing

@testable import DirnexCore

@Suite("Palette destinations")
struct PaletteDestinationTests {
    // MARK: - Fixtures

    private let search = SavedSearch(name: "All PDFs", query: FileQuery(nameContains: "pdf"))
    private let favorite = FavoriteEntry(path: .local("/Users/oleg/Dev"))
    private let iCloud = SidebarPlace.iCloudDrive(
        .local("/Users/oleg/Library/Mobile Documents/com~apple~CloudDocs")
    )
    private let cloud = CloudStorageMount(
        directoryName: "GoogleDrive-someone@gmail.com",
        providerID: "GoogleDrive",
        accountLabel: "someone@gmail.com",
        name: "Google Drive",
        path: .local("/Users/oleg/Library/CloudStorage/GoogleDrive-someone@gmail.com")
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

    private func volume(_ name: String, at path: String) -> MountedVolume {
        MountedVolume(
            name: name,
            path: .local(path),
            isRoot: path == "/",
            isRemovable: false,
            isEjectable: path != "/",
            isInternal: path == "/",
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
    }

    private func workspace(_ name: String) -> Workspace {
        Workspace(
            name: name,
            left: WorkspacePane(tabs: [WorkspaceTab(path: .local("/Users/oleg"))], activeTabIndex: 0),
            right: WorkspacePane(tabs: [WorkspaceTab(path: .local("/tmp"))], activeTabIndex: 0)
        )
    }

    private func groups(
        searches: [SavedSearch]? = nil,
        favorites: [FavoriteEntry]? = nil,
        volumes: [MountedVolume]? = nil,
        tags: [FinderTag]? = nil
    ) -> [SidebarPlaceGroup] {
        SidebarPlaces.groups(from: SidebarPlaceSources(
            searches: searches ?? [search],
            favorites: favorites ?? [favorite],
            cloud: [iCloud, .cloudMount(cloud), .photos],
            volumes: volumes ?? [volume("Macintosh HD", at: "/")],
            vaults: [vault],
            servers: [server],
            tags: tags ?? [tag]
        ))
    }

    // MARK: - Ids

    @Test("every place in the sidebar gets an id of its own, under the place prefix")
    func everyPlaceHasADistinctID() {
        let places = groups().flatMap(\.places)
        let ids = places.map(PaletteDestination.commandID(for:))
        // One of each of SidebarPlace's eleven kinds.
        #expect(places.count == 11)
        #expect(Set(ids).count == places.count)
        #expect(ids.allSatisfy { $0.hasPrefix(PaletteDestination.placePrefix) })
        #expect(ids.allSatisfy(PaletteDestination.isDestination(commandID:)))
    }

    @Test("an id names the place by its store's identity, so it reads the same tomorrow")
    func idsAreStable() {
        #expect(PaletteDestination.commandID(for: .recents) == "place.recents")
        #expect(PaletteDestination.commandID(for: .trash) == "place.trash")
        #expect(PaletteDestination.commandID(for: .savedSearch(search)) == "place.search:All PDFs")
        #expect(
            PaletteDestination.commandID(for: .favorite(favorite)) == "place.favorite:local:/Users/oleg/Dev"
        )
        #expect(
            PaletteDestination.commandID(for: .cloudMount(cloud)) == "place.cloud:GoogleDrive-someone@gmail.com"
        )
        #expect(PaletteDestination.commandID(for: .server(server)) == "place.server:NAS")
        #expect(
            PaletteDestination.commandID(for: .vault(vault)) == "place.vault:/Users/oleg/SecDocs.sparsebundle"
        )
    }

    @Test("a cloud mount keys on its directory, not on a display name a second account changes")
    func cloudMountKeysOnDirectory() {
        let renamed = CloudStorageMount(
            directoryName: cloud.directoryName,
            providerID: cloud.providerID,
            accountLabel: cloud.accountLabel,
            name: "Google Drive (someone@gmail.com)",
            path: cloud.path
        )
        #expect(PaletteDestination.commandID(for: .cloudMount(renamed))
            == PaletteDestination.commandID(for: .cloudMount(cloud)))
    }

    @Test("a tag's id folds case, as macOS does when it identifies a tag")
    func tagIDFoldsCase() {
        #expect(PaletteDestination.commandID(for: .tag(FinderTag(name: "red", color: .red)))
            == PaletteDestination.commandID(for: .tag(tag)))
        #expect(PaletteDestination.commandID(for: .tag(FinderTag(name: "Rose")))
            != PaletteDestination.commandID(for: .tag(tag)))
    }

    @Test("a pin and a volume at one path stay two rows")
    func kindIsPartOfTheID() {
        let path = "/Volumes/Backup"
        let pin = PaletteDestination.commandID(for: .favorite(FavoriteEntry(path: .local(path))))
        let disk = PaletteDestination.commandID(for: .volume(volume("Backup", at: path)))
        #expect(pin != disk)
    }

    @Test("a workspace named like a registry command cannot collide with it")
    func workspaceIDsStayOutOfTheRegistry() {
        let registry = Set(CommandCatalog.all.map(\.id))
        for name in ["save", "list", "Work"] {
            let id = PaletteDestination.commandID(forWorkspaceNamed: name)
            #expect(!registry.contains(id))
            #expect(PaletteDestination.isDestination(commandID: id))
        }
        #expect(registry.allSatisfy { !PaletteDestination.isDestination(commandID: $0) })
    }

    @Test("a user script's id is not a destination")
    func userScriptIsNotADestination() {
        #expect(!PaletteDestination.isDestination(commandID: "userScript.place.recents"))
    }

    // MARK: - Listing

    @Test("all() lists the places in sidebar order, then the workspaces in saved order")
    func allKeepsTheSidebarsOrder() {
        let current = groups()
        let destinations = PaletteDestination.all(
            places: current,
            workspaces: [workspace("Work"), workspace("Home")]
        )
        let expected = current.flatMap(\.places).map(PaletteDestination.place)
            + [.workspace(workspace("Work")), .workspace(workspace("Home"))]
        #expect(destinations == expected)
    }

    @Test("all() lists a place two groups both carry once, where it first appears")
    func allDropsDuplicates() {
        let doubled = groups() + [SidebarPlaceGroup(section: nil, places: [.recents, .tag(tag)])]
        let destinations = PaletteDestination.all(places: doubled, workspaces: [])
        #expect(destinations.count == groups().flatMap(\.places).count)
        #expect(destinations.first == .place(.recents))
    }

    @Test("a destination's row carries its id, the given words, and Go or Workspace")
    func commandRow() {
        let place = PaletteDestination.place(.favorite(favorite)).command(
            title: "Dev",
            keywords: ["Favorites"]
        )
        #expect(place.id == "place.favorite:local:/Users/oleg/Dev")
        #expect(place.title == "Dev")
        #expect(place.keywords == ["Favorites"])
        #expect(place.category == .navigation)
        #expect(place.shortcut == nil)

        let saved = PaletteDestination.workspace(workspace("Work")).command(title: "Work")
        #expect(saved.id == "openWorkspace.Work")
        #expect(saved.category == .workspace)
    }

    // MARK: - Resolving a pick

    @Test("a picked id resolves to the place the stores hold now")
    func resolvesEveryPlace() {
        let current = groups()
        for place in current.flatMap(\.places) {
            let id = PaletteDestination.commandID(for: place)
            #expect(PaletteDestination.resolve(id, places: current, workspaces: []) == .place(place))
        }
    }

    @Test("a pin renamed since it was picked still resolves, to its new name")
    func renamedPinResolvesToTheCurrentEntry() {
        let id = PaletteDestination.commandID(for: .favorite(favorite))
        var renamed = favorite
        renamed.name = "Projects"
        let resolved = PaletteDestination.resolve(
            id,
            places: groups(favorites: [renamed]),
            workspaces: []
        )
        #expect(resolved == .place(.favorite(renamed)))
    }

    @Test("a place that has gone resolves to nothing")
    func removedPlaceResolvesToNothing() {
        let pinID = PaletteDestination.commandID(for: .favorite(favorite))
        let searchID = PaletteDestination.commandID(for: .savedSearch(search))
        let tagID = PaletteDestination.commandID(for: .tag(tag))
        let emptied = groups(searches: [], favorites: [], tags: [])
        #expect(PaletteDestination.resolve(pinID, places: emptied, workspaces: []) == nil)
        #expect(PaletteDestination.resolve(searchID, places: emptied, workspaces: []) == nil)
        #expect(PaletteDestination.resolve(tagID, places: emptied, workspaces: []) == nil)
    }

    @Test("a saved search renamed since it was picked no longer answers to the old name")
    func renamedSearchResolvesToNothing() {
        let id = PaletteDestination.commandID(for: .savedSearch(search))
        var renamed = search
        renamed.name = "PDFs"
        #expect(
            PaletteDestination.resolve(id, places: groups(searches: [renamed]), workspaces: []) == nil
        )
    }

    @Test("a workspace resolves by its exact name, and not once it is gone")
    func resolvesWorkspaces() {
        let saved = [workspace("Work"), workspace("work")]
        #expect(PaletteDestination.resolve("openWorkspace.Work", places: [], workspaces: saved)
            == .workspace(workspace("Work")))
        #expect(PaletteDestination.resolve("openWorkspace.work", places: [], workspaces: saved)
            == .workspace(workspace("work")))
        #expect(PaletteDestination.resolve("openWorkspace.Work", places: [], workspaces: []) == nil)
    }

    @Test("a registry command or a user script resolves to no destination")
    func nonDestinationsResolveToNothing() {
        for id in ["file.copy", "workspace.save", "userScript.Hello", "place", ""] {
            #expect(
                PaletteDestination.resolve(id, places: groups(), workspaces: [workspace("save")]) == nil
            )
        }
    }

    // MARK: - Recents and vaults

    @Test("a place inside an unlocked vault is not remembered, and nothing else is affected")
    func vaultPlacesStayOutOfRecents() {
        let mounts = ["/Volumes/SecDocs"]
        let inside = PaletteDestination.place(
            .favorite(FavoriteEntry(path: .local("/Volumes/SecDocs/taxes")))
        )
        let theVolume = PaletteDestination.place(.volume(volume("SecDocs", at: "/Volumes/SecDocs")))
        let beside = PaletteDestination.place(
            .favorite(FavoriteEntry(path: .local("/Volumes/SecDocsBackup")))
        )
        #expect(!inside.isRememberable(vaultMountPoints: mounts))
        #expect(!theVolume.isRememberable(vaultMountPoints: mounts))
        #expect(beside.isRememberable(vaultMountPoints: mounts))
        #expect(PaletteDestination.place(.vault(vault)).isRememberable(vaultMountPoints: mounts))
        #expect(
            PaletteDestination.place(.savedSearch(search)).isRememberable(vaultMountPoints: mounts)
        )
        #expect(
            PaletteDestination.workspace(workspace("Work")).isRememberable(vaultMountPoints: mounts)
        )
    }

    @Test("with no vault unlocked, every place is remembered")
    func everythingIsRememberedWithoutAVault() {
        for place in groups().flatMap(\.places) {
            #expect(PaletteDestination.place(place).isRememberable(vaultMountPoints: []))
        }
    }
}
