import Foundation
import Testing

@testable import DirnexCore

/// Which sidebar place a pane is in — where View ▸ Focus Sidebar lands.
@Suite("Sidebar place locator")
struct SidebarPlaceLocatorTests {
    // MARK: - Fixtures

    private static func volume(_ name: String, at path: String, isRoot: Bool = false) -> MountedVolume {
        MountedVolume(
            name: name,
            path: .local(path),
            isRoot: isRoot,
            isRemovable: false,
            isEjectable: !isRoot,
            isInternal: isRoot,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
    }

    private let home = SidebarPlace.favorite(FavoriteEntry(path: .local("/Users/u")))
    private let dev = SidebarPlace.favorite(FavoriteEntry(path: .local("/Users/u/Dev")))
    private let downloads = SidebarPlace.favorite(FavoriteEntry(path: .local("/Users/u/Downloads")))
    private let iCloud = SidebarPlace.iCloudDrive(
        .local("/Users/u/Library/Mobile Documents/com~apple~CloudDocs")
    )
    private let drive = SidebarPlace.cloudMount(CloudStorageMount(
        directoryName: "GoogleDrive-a@b.com",
        providerID: "GoogleDrive",
        accountLabel: "a@b.com",
        name: "Google Drive",
        path: .local("/Users/u/Library/CloudStorage/GoogleDrive-a@b.com"),
        entryDirectory: .local("/Users/u/Library/CloudStorage/GoogleDrive-a@b.com/My Drive")
    ))
    private let macintoshHD = SidebarPlace.volume(volume("Macintosh HD", at: "/", isRoot: true))
    private let media = SidebarPlace.volume(volume("media", at: "/Volumes/media"))
    private let vaultLocation = VaultLocation(
        imagePath: "/Users/u/SecDocs.sparsebundle",
        volumeName: "SecDocs"
    )
    private let sftpLocation = SFTPLocation(host: "mac", username: "u")
    private var server: SidebarPlace {
        .server(ServerConnection(
            name: "Mac",
            endpoint: .sftp(location: sftpLocation, authentication: .password)
        ))
    }

    private let nas = SidebarPlace.server(ServerConnection(
        name: "NAS",
        endpoint: .smb(SMBLocation(host: "nas.local", share: "media", username: "u"))
    ))
    private let invoices = SavedSearch(name: "Invoices", query: FileQuery(nameContains: "invoice"))
    private let red = FinderTag(name: "Red", color: .red)

    /// The sidebar's own order: Recents, Searches, Favorites, Cloud, Volumes, Vaults, Servers, Tags,
    /// Trash.
    private var places: [SidebarPlace] {
        [
            .recents, .savedSearch(invoices),
            home, dev, downloads,
            iCloud, .photos, drive,
            macintoshHD, media,
            .vault(vaultLocation),
            server, nas,
            .tag(red),
            .trash
        ]
    }

    private func place(
        _ path: VFSPath,
        query: FileQuery? = nil,
        scope: VFSPath? = nil,
        archiveFile: VFSPath? = nil,
        vaults: [String: String] = [:],
        among places: [SidebarPlace]? = nil
    ) -> SidebarPlace? {
        SidebarPlaceLocator.place(
            for: SidebarPaneLocation(
                path: path,
                searchQuery: query,
                searchScope: scope,
                archiveFile: archiveFile
            ),
            among: places ?? self.places,
            vaultMountPoints: vaults
        )
    }

    // MARK: - Folders

    @Test("a pane standing exactly at a pinned folder lands on that pin")
    func exactFavorite() {
        #expect(place(.local("/Users/u/Dev")) == dev)
        #expect(place(.local("/Users/u")) == home)
    }

    @Test("a folder inside several places lands on the deepest of them")
    func deepestWins() {
        #expect(place(.local("/Users/u/Dev/Common/Dirnex")) == dev)
        #expect(place(.local("/Users/u/Music/2024")) == home)
    }

    @Test("a folder no pin holds lands on its volume")
    func volumes() {
        #expect(place(.local("/private/tmp")) == macintoshHD)
        #expect(place(.local("/Volumes/media/Films")) == media)
        #expect(place(.local("/Volumes/media")) == media)
    }

    /// A prefix is not an ancestor: `/Users/u/Developer` is beside Dev, not inside it.
    @Test("a sibling sharing a name prefix is not inside the pin")
    func prefixIsNotAncestry() {
        #expect(place(.local("/Users/u/Developer")) == home)
    }

    @Test("of two places rooted at the same folder, the first in sidebar order wins")
    func tiesGoToSidebarOrder() {
        let rootPin = SidebarPlace.favorite(FavoriteEntry(path: .local("/")))
        #expect(place(.local("/private/tmp"), among: [rootPin, macintoshHD]) == rootPin)
        #expect(place(.local("/private/tmp"), among: [macintoshHD, rootPin]) == macintoshHD)
    }

    // MARK: - Cloud

    /// The case that was reported: the merged listing is `icloud:/iCloud Drive` while the row
    /// names the CloudDocs container, so the old exact-path rule matched nothing.
    @Test("iCloud Drive's merged listing lands on iCloud Drive")
    func iCloudMergedListing() {
        #expect(place(VFSPath(backend: .icloud, path: "/iCloud Drive")) == iCloud)
    }

    @Test("a folder opened from iCloud Drive — loose or in an app's library — is still iCloud Drive")
    func iCloudFolders() {
        let root = "/Users/u/Library/Mobile Documents"
        #expect(place(.local("\(root)/com~apple~CloudDocs/Car")) == iCloud)
        #expect(place(.local("\(root)/com~apple~Pages/Documents/Drafts")) == iCloud)
    }

    @Test("anywhere in the Photos library is Photos")
    func photosLibrary() {
        #expect(place(VFSPath(backend: .photos, path: "/")) == .photos)
        #expect(place(VFSPath(backend: .photos, path: "/2023/2023-04")) == .photos)
    }

    /// The row opens `My Drive`, one level down, but the mount's own root belongs to it too.
    @Test("a provider mount holds its root and everything under it")
    func providerMount() {
        let mount = "/Users/u/Library/CloudStorage/GoogleDrive-a@b.com"
        #expect(place(.local(mount)) == drive)
        #expect(place(.local("\(mount)/My Drive/Job")) == drive)
        #expect(place(.local("/Users/u/Library/CloudStorage")) == home)
    }

    // MARK: - Results tabs

    @Test("the Trash tab lands on the Trash")
    func trashTab() {
        #expect(place(VFSPath(backend: .trash, path: "/Trash")) == .trash)
    }

    @Test("the Recents tab lands on Recents, and a search tab of the same name does not")
    func recentsTab() {
        #expect(place(SidebarPlaceLocator.recentsPath) == .recents)
        let lookalike = place(
            SidebarPlaceLocator.recentsPath,
            query: FileQuery(nameContains: "Recents")
        )
        #expect(lookalike == nil)
    }

    @Test("a saved search's tab lands on that search, and only with the same scope")
    func savedSearchTab() {
        let tab = VFSPath(backend: .search, path: "/name contains invoice")
        #expect(place(tab, query: invoices.query) == .savedSearch(invoices))
        #expect(place(tab, query: invoices.query, scope: .local("/Users/u/Dev")) == nil)
        #expect(place(tab, query: FileQuery(nameContains: "receipt")) == nil)
    }

    @Test("a tag's tab lands on the tag")
    func tagTab() {
        let tab = VFSPath(backend: .search, path: "/Red")
        #expect(place(tab, query: FileQuery(tags: ["Red"])) == .tag(red))
        #expect(place(tab, query: FileQuery(tags: ["Red"]), scope: .local("/Users/u")) == nil)
    }

    // MARK: - Vaults, servers, archives

    @Test("an unlocked vault holds its volume, and a locked one holds nothing")
    func unlockedVault() {
        let inside = VFSPath.local("/Volumes/SecDocs/Tax")
        let mounted = [vaultLocation.resolvedImagePath: "/Volumes/SecDocs"]
        #expect(place(inside, vaults: mounted) == .vault(vaultLocation))
        #expect(place(inside) == macintoshHD)
    }

    @Test("a pane on a connected server lands on the saved server, or on a pin deeper inside it")
    func connectedServer() {
        let path = VFSPath(backend: .sftp(sftpLocation), path: "/Users/u/Projects")
        #expect(place(path) == server)

        let pin = SidebarPlace.favorite(FavoriteEntry(path: path))
        #expect(place(path.appending("app"), among: [server, pin]) == pin)
    }

    @Test("a server this sidebar has not saved is no place")
    func unsavedServer() {
        let other = SFTPLocation(host: "elsewhere", username: "u")
        #expect(place(VFSPath(backend: .sftp(other), path: "/")) == nil)
    }

    /// SMB has no backend: a share is mounted, and the volume answers for it.
    @Test("a saved SMB server holds nothing of its own")
    func smbServer() {
        #expect(place(.local("/Volumes/media/x"), among: [nas, media]) == media)
        #expect(place(.local("/Volumes/media/x"), among: [nas]) == nil)
    }

    @Test("inside an archive, the folder holding the archive answers")
    func insideArchive() {
        let file = VFSPath.local("/Users/u/Downloads/pkg.zip")
        let inside = VFSPath(backend: .archive(forArchiveAt: file.path), path: "/docs")
        #expect(place(inside, archiveFile: file) == downloads)
        // Without the file there is nothing to go on.
        #expect(place(inside) == nil)
    }

    @Test("a pin inside the archive beats the folder holding it")
    func pinInsideArchive() {
        let file = VFSPath.local("/Users/u/Downloads/pkg.zip")
        let inside = VFSPath(backend: .archive(forArchiveAt: file.path), path: "/docs")
        let pin = SidebarPlace.favorite(FavoriteEntry(path: inside))
        #expect(place(inside.appending("api"), archiveFile: file, among: places + [pin]) == pin)
    }

    @Test("with no place holding the location, there is no answer")
    func nothing() {
        #expect(place(.local("/private/tmp"), among: [home, .trash]) == nil)
        #expect(
            place(VFSPath(backend: .search, path: "/x"), query: FileQuery(nameContains: "x")) == nil
        )
    }
}
