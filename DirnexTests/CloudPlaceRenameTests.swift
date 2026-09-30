import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Renaming a sidebar **Cloud** row — iCloud Drive, Photos, or a provider mount.
///
/// The claim is that the new name reaches every surface that names the place, not only the row: a
/// rename that stopped at the sidebar would leave the path bar and the tab calling the same place
/// something else. The names are handed in wherever a surface allows it, because this target runs
/// inside the app and the store is the developer's own sidebar (docs/NOTES.md ▸ Testing).
@Suite("Cloud row rename")
@MainActor
struct CloudPlaceRenameTests {
    private let mount = CloudStorageMount(
        directoryName: "Dropbox-Home",
        providerID: "Dropbox",
        accountLabel: "Home",
        name: "Dropbox",
        path: .local("/Users/u/Library/CloudStorage/Dropbox-Home")
    )
    private let renamed = SidebarItemNames(names: [
        "icloud": "Personal",
        "photos": "Pictures",
        "mount:Dropbox-Home": "Work"
    ])
    private let iCloud = SidebarPlace.iCloudDrive(.local("/Users/u/Library/Mobile Documents"))

    // MARK: - The sidebar row and the Places menu

    @Test("a renamed row is drawn by its new name")
    func presentationUsesTheName() {
        #expect(SidebarPlacePresentation.title(for: iCloud, names: renamed) == "Personal")
        #expect(SidebarPlacePresentation.title(for: .photos, names: renamed) == "Pictures")
        #expect(SidebarPlacePresentation.title(for: .cloudMount(mount), names: renamed) == "Work")
    }

    @Test("a row nobody renamed keeps the name the app gives it")
    func presentationKeepsTheDefault() {
        let none = SidebarItemNames()
        #expect(
            SidebarPlacePresentation.title(for: iCloud, names: none) == CloudPlaceTitle.iCloudDriveDefault
        )
        #expect(
            SidebarPlacePresentation.title(for: .photos, names: none) == PhotosPresentation.libraryTitle
        )
        #expect(SidebarPlacePresentation.title(for: .cloudMount(mount), names: none) == "Dropbox")
    }

    /// The narrowness half: a stored name under an identity nothing else uses must not leak onto
    /// a place outside the section.
    @Test("a place outside the Cloud section is not renamed by the store")
    func otherPlacesIgnoreTheNames() {
        let favorite = FavoriteEntry(name: "Work", path: .local("/Users/u/Work"))
        #expect(CloudPlaceTitle.title(for: .favorite(favorite), names: renamed) == nil)
        #expect(CloudPlaceTitle.title(for: .recents, names: renamed) == nil)
        #expect(SidebarPlacePresentation.title(for: .favorite(favorite), names: renamed) == "Work")
    }

    // MARK: - The path bar

    /// The crumbs' titles. The row opens with the Places glyph, an image-only button, which is left
    /// out; the branch chip at the far end is not a button.
    private func crumbTitles(_ bar: PathBarView) -> [String] {
        bar.crumbStack.arrangedSubviews.dropFirst().compactMap { ($0 as? NSButton)?.title }
    }

    private func bar(_ path: VFSPath, names: @escaping () -> SidebarItemNames) -> PathBarView {
        let bar = PathBarView(frame: NSRect(x: 0, y: 0, width: 400, height: 20))
        bar.cloudPlaceNames = names
        bar.setPath(path)
        return bar
    }

    @Test("the root crumb of iCloud Drive and of the Photos library follows the rename")
    func pathBarRootCrumbs() {
        let renamed = renamed
        #expect(crumbTitles(bar(ICloudLocation.mergedPath) { renamed }) == ["Personal"])
        let month = VFSPath(backend: .photos, path: "/2023/2023-04")
        #expect(crumbTitles(bar(month) { renamed }) == ["Pictures", "2023", "2023-04"])
    }

    /// `setPath` is a no-op for the location already on screen, so a rename made while the pane
    /// stands in the place would otherwise wait for the next navigation to show.
    @Test("the path bar redraws in place when the names change")
    func pathBarReloadsInPlace() {
        let source = NamesSource()
        let bar = bar(ICloudLocation.mergedPath) { source.names }
        #expect(crumbTitles(bar) == [CloudPlaceTitle.iCloudDriveDefault])

        source.names = renamed
        bar.setPath(ICloudLocation.mergedPath)
        #expect(crumbTitles(bar) == [CloudPlaceTitle.iCloudDriveDefault])
        bar.reloadLocation()
        #expect(crumbTitles(bar) == ["Personal"])
    }

    // MARK: - The tab

    /// A folder in `~/Library/CloudStorage` whose mounts are the given directory names.
    private func cloudHome(_ mounts: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudPlaceRenameTests-\(UUID().uuidString)")
        for mount in mounts {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Library/CloudStorage/\(mount)"),
                withIntermediateDirectories: true
            )
        }
        return home
    }

    @Test("a tab at a mount's root is called what the row is called")
    func mountRootTitle() throws {
        let home = try cloudHome(["Dropbox-Home", "Dropbox-Personal"])
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = CloudStorageMounts.cloudStorage(home: home.path)
        let root = storage.appending("Dropbox-Home")

        #expect(CloudPlaceTitle.mountRoot(root, home: home.path, names: renamed) == "Work")
        // Unrenamed, it is the sidebar's own label — here disambiguated by the second account —
        // rather than the folder's `Dropbox-Home`.
        #expect(
            CloudPlaceTitle.mountRoot(root, home: home.path, names: SidebarItemNames())
                == "Home — Dropbox"
        )
    }

    @Test("only a mount's root takes the row's name")
    func mountRootIsNarrow() throws {
        let home = try cloudHome(["Dropbox-Home"])
        defer { try? FileManager.default.removeItem(at: home) }
        let storage = CloudStorageMounts.cloudStorage(home: home.path)

        // Below the root a folder has a name of its own.
        let inside = storage.appending("Dropbox-Home").appending("Team")
        #expect(CloudPlaceTitle.mountRoot(inside, home: home.path, names: renamed) == nil)
        // The parent is not a place anybody renamed, and neither is a folder that is not there.
        #expect(CloudPlaceTitle.mountRoot(storage, home: home.path, names: renamed) == nil)
        let missing = storage.appending("Box-Box")
        #expect(CloudPlaceTitle.mountRoot(missing, home: home.path, names: renamed) == nil)
        #expect(CloudPlaceTitle.mountRoot(.local("/Users/u/Work"), home: home.path) == nil)
    }

    /// The merged listing's path ends in an English identity that is never displayed, and its tab
    /// no longer captures a title of its own — so both have to come from the same place.
    @Test("the iCloud Drive tab is named by the row's title, never by its identity")
    func iCloudTabTitle() {
        // The merge installs no chip label of its own: a string captured when the listing was
        // gathered would go on naming the tab after the row was renamed.
        let pane = PanelViewController(
            backend: LocalBackend(), restoration: nil, defaultPath: .local("/"), restorationKey: nil
        )
        #expect(pane.iCloudPresentation().title == nil)

        let tab = PanelTab(path: ICloudLocation.mergedPath)
        #expect(tab.title == CloudPlaceTitle.iCloudDrive())
        #expect(ICloudLocation.mergedPath.displayName == CloudPlaceTitle.iCloudDrive())
    }

    /// The folder the merged listing shows loose is iCloud Drive itself, so a tab parked there by a
    /// typed path is called what the row is called, and follows a rename of it.
    @Test("a tab at the CloudDocs container is called what the iCloud Drive row is called")
    func iCloudContainerTitle() {
        let home = "/Users/u"
        let container = ICloudDrive.cloudDocs(home: home)

        #expect(CloudPlaceTitle.iCloudContainer(container, home: home, names: renamed) == "Personal")
        #expect(
            CloudPlaceTitle.iCloudContainer(container, home: home, names: SidebarItemNames())
                == CloudPlaceTitle.iCloudDriveDefault
        )
        // Through the surfaces that ask, on this Mac's own container.
        let real = ICloudDrive.cloudDocs()
        #expect(real.displayName == CloudPlaceTitle.iCloudDrive())
        #expect(PanelTab(path: real).title == CloudPlaceTitle.iCloudDrive())
    }

    @Test("only the CloudDocs container itself takes iCloud Drive's name")
    func iCloudContainerIsNarrow() {
        let home = "/Users/u"
        let container = ICloudDrive.cloudDocs(home: home)
        let others: [VFSPath] = [
            // A loose folder, including one that happens to be called `Documents`.
            container.appending("Car"),
            container.appending("Documents"),
            // The machinery around it, and an app library, which is named for its app instead.
            ICloudDrive.mobileDocuments(home: home),
            ICloudDrive.mobileDocuments(home: home).appending("com~apple~Pages").appending(
                "Documents"
            ),
            // Another account's container is not this user's iCloud Drive.
            ICloudDrive.cloudDocs(home: "/Users/someone"),
            .local("/Users/u/com~apple~CloudDocs")
        ]
        for path in others {
            #expect(
                CloudPlaceTitle.iCloudContainer(path, home: home, names: renamed) == nil,
                "\(path.path)"
            )
        }
    }

    // MARK: - The store

    @Test("names round-trip, and forgetting the last one leaves no key behind")
    func storeRoundTrips() {
        let defaults = ScratchDefaults.fresh()
        CloudPlaceNameStore.save(renamed, to: defaults)
        #expect(CloudPlaceNameStore.load(from: defaults) == renamed)

        CloudPlaceNameStore.save(SidebarItemNames(), to: defaults)
        #expect(CloudPlaceNameStore.load(from: defaults) == SidebarItemNames())
        #expect(defaults.object(forKey: "Dirnex.cloudPlaceNames") == nil)
    }

    /// Every sidebar and pane observes the app's own domain only, so a test writing names into a
    /// scratch one cannot redraw the windows other suites keep alive.
    @Test("a save announces the domain it wrote to")
    func notificationNamesItsDomain() {
        let defaults = ScratchDefaults.fresh()
        let counter = NotificationCounter()
        let center = NotificationCenter.default
        let app = center.addObserver(
            forName: CloudPlaceNameStore.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in counter.app += 1 }
        let scratch = center.addObserver(
            forName: CloudPlaceNameStore.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in counter.scratch += 1 }
        defer {
            center.removeObserver(app)
            center.removeObserver(scratch)
        }

        CloudPlaceNameStore.save(renamed, to: defaults)
        #expect(counter.scratch == 1)
        #expect(counter.app == 0)
    }

    // MARK: - The sidebar's menu and F2

    private func loadedSidebar() -> SidebarViewController {
        let sidebar = SidebarViewController()
        sidebar.loadView()
        return sidebar
    }

    private func actions(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.action.map(NSStringFromSelector) ?? "-" }
    }

    @Test("a Cloud row's menu offers Open and Rename, and Restore only once it has been renamed")
    func menuOffersRestoreOnlyWhenRenamed() {
        let sidebar = loadedSidebar()

        let fresh = NSMenu()
        sidebar.buildCloudPlaceMenu(fresh, for: .cloudMount(mount), names: SidebarItemNames())
        #expect(actions(fresh) == ["openCloudPlaceItem:", "-", "renameCloudPlaceItem:"])

        let named = NSMenu()
        sidebar.buildCloudPlaceMenu(named, for: .cloudMount(mount), names: renamed)
        #expect(actions(named) == [
            "openCloudPlaceItem:", "-", "renameCloudPlaceItem:", "restoreCloudPlaceNameItem:"
        ])
        // Each item carries the place's identity rather than a row, which a rebuild would move.
        let commands = named.items.filter { !$0.isSeparatorItem }
        #expect(commands.allSatisfy { ($0.representedObject as? String) == "mount:Dropbox-Home" })
        #expect(commands.allSatisfy { $0.target === sidebar })
    }

    /// Open reaches the same delegate call a click on the row makes, for all three kinds of place.
    @Test("Open on a Cloud row activates the place a click would")
    func openActivatesThePlace() throws {
        let sidebar = loadedSidebar()
        let recorder = CloudOpenRecorder()
        sidebar.delegate = recorder
        sidebar.rows = [.place(iCloud), .place(.photos), .place(.cloudMount(mount))]

        for place in [iCloud, SidebarPlace.photos, .cloudMount(mount)] {
            let menu = NSMenu()
            sidebar.buildCloudPlaceMenu(menu, for: place, names: SidebarItemNames())
            let open = try #require(menu.items.first)
            let action = try #require(open.action)
            _ = sidebar.perform(action, with: open)
        }
        #expect(recorder.events == ["icloud", "photos", mount.path.path])
    }

    @Test("F2 is offered on a selected Cloud row, and not on a favorite")
    func f2ReachesCloudRows() {
        let sidebar = loadedSidebar()
        let item = NSMenuItem(
            title: "Rename",
            action: NSSelectorFromString("renameSelection:"),
            keyEquivalent: ""
        )
        let favorite = FavoriteEntry(path: .local("/Users/u/Work"))
        sidebar.rows = [.place(.photos), .place(.favorite(favorite))]
        sidebar.tableView.reloadData()

        sidebar.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(sidebar.selectedCloudPlace == .photos)
        #expect(sidebar.validateMenuItem(item))

        sidebar.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(sidebar.selectedCloudPlace == nil)
        #expect(sidebar.validateMenuItem(item) == false)
    }
}

/// A names source a test can change after the path bar has captured it.
@MainActor
private final class NamesSource {
    var names = SidebarItemNames()
}

/// Counts deliveries; `@unchecked` because `addObserver(forName:…)` takes a `@Sendable` block, and a
/// post with a `nil` queue delivers synchronously on the posting thread.
private final class NotificationCounter: @unchecked Sendable {
    var app = 0
    var scratch = 0
}

/// Records which place a sidebar asked the window to open; every other verb is ignored.
@MainActor
private final class CloudOpenRecorder: SidebarViewControllerDelegate {
    var events: [String] = []

    func sidebar(_ sidebar: SidebarViewController, didActivate path: VFSPath) { events.append(
        path.path
    ) }
    func sidebarDidActivateICloud(_ sidebar: SidebarViewController) { events.append("icloud") }
    func sidebarDidActivatePhotos(_ sidebar: SidebarViewController) { events.append("photos") }

    func sidebar(_ sidebar: SidebarViewController, didActivateFavorite entry: FavoriteEntry) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateSavedSearch savedSearch: SavedSearch) {}
    func sidebarDidActivateRecents(_ sidebar: SidebarViewController) {}
    func sidebarDidActivateTrash(_ sidebar: SidebarViewController) {}
    func sidebarDidRequestEmptyTrash(_ sidebar: SidebarViewController) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateServer server: ServerConnection) {}
    func sidebar(_ sidebar: SidebarViewController, didEditServer server: ServerConnection) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateVault vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestLockOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didRequestRenameOf vault: VaultLocation) {}
    func sidebar(_ sidebar: SidebarViewController, didActivateTag tag: FinderTag) {}
    func sidebarDidClickEmptyArea(_ sidebar: SidebarViewController) {}
}
