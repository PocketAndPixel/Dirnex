import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// How **Go ▸ Places** renders the shared place list (PLAN.md §M20).
///
/// The claims worth pinning are the ones no screenshot of a *populated* menu would expose: that a
/// section folded shut in the sidebar is still listed here, that every destination carries the
/// payload and the action it is dispatched by, and that an empty section says so rather than opening
/// onto nothing. The groups are handed in rather than read, because this target runs *inside the
/// app* — sources read from the stores would be the sidebar of whoever is running the tests.
@Suite("Places menu")
@MainActor
struct PlacesMenuTests {
    private let volume = MountedVolume(
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
    private let vault = VaultLocation(
        imagePath: "/Users/oleg/SecDocs.sparsebundle",
        volumeName: "SecDocs"
    )

    private func render(_ groups: [SidebarPlaceGroup], unlockedVaults: Set<String> = []) -> NSMenu {
        let menu = NSMenu()
        PlacesMenu().build(menu, groups: groups, unlockedVaults: unlockedVaults)
        return menu
    }

    private func submenu(_ menu: NSMenu, _ section: SidebarSection) -> NSMenu? {
        menu.items.first { $0.title == LocalizedCatalog.title(for: section) }?.submenu
    }

    // MARK: - Shape

    @Test("the headerless places render bare and the sections as submenus")
    func topLevelShape() {
        let menu = render([
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .volumes, places: [.volume(volume)]),
            SidebarPlaceGroup(section: nil, places: [.trash])
        ])
        let titles = menu.items.map(\.title)
        #expect(titles.contains(SidebarPlacePresentation.title(for: .recents)))
        #expect(titles.contains(SidebarPlacePresentation.title(for: .trash)))
        // The volume is one level in, not beside them.
        #expect(!titles.contains(volume.name))
        #expect(submenu(menu, .volumes)?.items.map(\.title) == [volume.name])
    }

    @Test("the Trash is set off from the sections above it, and nothing dangles at the top")
    func separators() {
        let menu = render([
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .volumes, places: [.volume(volume)]),
            SidebarPlaceGroup(section: nil, places: [.trash])
        ])
        // A leading separator would draw as a stray line at the top of the menu.
        #expect(menu.items.first?.isSeparatorItem == false)
        let trashRow = menu.indexOfItem(withTitle: SidebarPlacePresentation.title(for: .trash))
        let precededBySeparator = trashRow > 0 && menu.items[trashRow - 1].isSeparatorItem
        #expect(precededBySeparator)
    }

    // MARK: - Dispatch

    @Test("every destination carries its place and the action that opens it")
    func itemsCarryTheirPlace() {
        let menu = render([
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .vaults, places: [.vault(vault)])
        ])
        // Assert the selector by *name*: `#selector` would keep naming the right one even after the
        // window controller stopped implementing it, which is the state this exists to catch
        // (docs/NOTES.md).
        let opensPlace = NSSelectorFromString("openPlace:")
        #expect(BrowserWindowController.instancesRespond(to: opensPlace))

        let vaultItem = submenu(menu, .vaults)?.items.first
        #expect(vaultItem?.action == opensPlace)
        // Nil target, so the action travels the responder chain to the front window — the menu bar
        // is one object shared by every window.
        #expect(vaultItem?.target == nil)
        #expect((vaultItem?.representedObject as? PlaceBox)?.place == .vault(vault))
    }

    @Test("a place is carried whole, so a store changing under an open menu cannot redirect it")
    func payloadIsThePlaceNotAnIndex() {
        let menu = render([SidebarPlaceGroup(section: .volumes, places: [.volume(volume)])])
        let box = submenu(menu, .volumes)?.items.first?.representedObject as? PlaceBox
        #expect(box?.place.path == volume.path)
    }

    // MARK: - Empty sections

    @Test("an empty section says so instead of opening onto nothing")
    func emptySectionHasADisabledPlaceholder() {
        let menu = render([SidebarPlaceGroup(section: .favorites, places: [])])
        let items = submenu(menu, .favorites)?.items ?? []
        #expect(items.count == 1)
        #expect(items.first?.isEnabled == false)
        #expect(items.first?.action == nil)
    }

    // MARK: - What the sidebar does and this does not

    // The fold-independence claim is pinned in the *core* suite (`SidebarPlacesTests`), not here, and
    // deliberately: setting it up means writing `SidebarSectionCollapseStore`, and in a target that
    // runs inside the app that is the sidebar of whoever is running the tests — folded shut for real,
    // in every window, by a test run (docs/NOTES.md). The renderer below is handed its groups and has
    // no way to consult a fold, which is the property that matters and is visible in its signature.

    @Test("a vault's padlock reports the state the sidebar shows")
    func vaultLockStateIsCarried() {
        let groups = [SidebarPlaceGroup(section: .vaults, places: [.vault(vault)])]
        let locked = render(groups)
        let unlocked = render(groups, unlockedVaults: [vault.resolvedImagePath])
        // Not a comparison of images: two `NSImage`s built from the same symbol are not equal, so
        // the claim is about the name each state resolves to — which is what the sidebar's own cell
        // asks for too.
        #expect(SidebarPlacePresentation.vaultSymbolName(isUnlocked: false) == "lock.fill")
        #expect(SidebarPlacePresentation.vaultSymbolName(isUnlocked: true) == "lock.open.fill")
        let lockedHasImage = submenu(locked, .vaults)?.items.first?.image != nil
        let unlockedHasImage = submenu(unlocked, .vaults)?.items.first?.image != nil
        #expect(lockedHasImage)
        #expect(unlockedHasImage)
    }
}
