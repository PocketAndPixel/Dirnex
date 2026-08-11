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

    // MARK: - The 1–9 jump keys

    /// Every key equivalent in the tree, which is the form the interesting claim takes: AppKit's
    /// search recurses into submenus and fires the *first* match in menu order, so a digit that
    /// appears twice is a digit whose meaning depends on where it happens to sit.
    private func digitsInTree(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            let own = item.keyEquivalent.isEmpty ? [] : [item.keyEquivalent]
            return own + (item.submenu.map { digitsInTree($0) } ?? [])
        }
    }

    private func places(_ menu: NSMenu, _ section: SidebarSection) -> [(String, String)] {
        (submenu(menu, section)?.items ?? []).map { ($0.title, $0.keyEquivalent) }
    }

    private var threeSections: [SidebarPlaceGroup] {
        [
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .volumes, places: [.volume(volume)]),
            SidebarPlaceGroup(section: .vaults, places: [.vault(vault)]),
            SidebarPlaceGroup(section: nil, places: [.trash])
        ]
    }

    @Test("the top level numbers its destinations, and a section header takes no digit")
    func topLevelNumbering() {
        let menu = render(threeSections)
        PlacesDigits.hand(to: menu, root: menu)
        let numbered = menu.items.filter { !$0.keyEquivalent.isEmpty }.map { (
            $0.title,
            $0.keyEquivalent
        ) }
        #expect(numbered.map(\.0) == [
            SidebarPlacePresentation.title(for: .recents),
            SidebarPlacePresentation.title(for: .trash)
        ])
        #expect(numbered.map(\.1) == ["1", "2"])
        // A header carries a submenu, and AppKit neither draws nor fires a key equivalent on one
        // (measured; see `PlacesDigits`). Numbering it would print a promise the menu cannot keep —
        // and it would consume the number, which is what pushed the Trash to "8" when it was tried.
        for section in [SidebarSection.volumes, .vaults] {
            let header = menu.items.first { $0.title == LocalizedCatalog.title(for: section) }
            #expect(header?.submenu != nil)
            #expect(header?.keyEquivalent.isEmpty == true)
        }
    }

    @Test("the digits are bare, with no modifier")
    func digitsAreBare() {
        let menu = render(threeSections)
        PlacesDigits.hand(to: menu, root: menu)
        let recents = menu.items.first { !$0.keyEquivalent.isEmpty }
        // ⌘1 would be a chord competing with the app's own; this is a key typed while the menu is up.
        #expect(recents?.keyEquivalentModifierMask == [])
    }

    @Test("opening a section moves the digits into it, so no digit means two things at once")
    func openingASectionTakesTheDigits() {
        let menu = render(threeSections)
        PlacesDigits.hand(to: menu, root: menu)
        guard let volumes = submenu(menu, .volumes) else { Issue.record("no Volumes"); return }

        PlacesMenu().sectionDelegate.menuWillOpen(volumes)

        #expect(places(menu, .volumes).map(\.1) == ["1"])
        // The root's own two have given theirs up — measured, an open submenu is given no
        // precedence, so leaving "1" on Recents means Recents wins from inside Volumes.
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
        let all = digitsInTree(menu)
        #expect(all == ["1"])
        #expect(Set(all).count == all.count)
    }

    @Test("leaving a section hands the digits back to the top level")
    func leavingASectionRestoresTheTopLevel() async throws {
        let menu = render(threeSections)
        let delegate = PlacesMenu().sectionDelegate
        PlacesDigits.hand(to: menu, root: menu)
        let volumes = try #require(submenu(menu, .volumes))

        delegate.menuWillOpen(volumes)
        delegate.menuDidClose(volumes)
        // The restore is deferred a turn, so an open landing in the same pass can win it instead.
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            menu.items.compactMap { $0.keyEquivalent.isEmpty ? nil : $0.keyEquivalent } == ["1", "2"]
        )
        #expect(places(menu, .volumes).map(\.1) == [""])
    }

    @Test("stepping from one section to the next leaves the digits in the new one")
    func movingBetweenSectionsKeepsThemInFront() async throws {
        let menu = render(threeSections)
        let delegate = PlacesMenu().sectionDelegate
        let volumes = try #require(submenu(menu, .volumes))
        let vaults = try #require(submenu(menu, .vaults))

        delegate.menuWillOpen(volumes)
        // AppKit does not promise close-before-open, so the close of the section being left can land
        // after the open of the one being entered; the restore must lose that race, not win it.
        delegate.menuDidClose(volumes)
        delegate.menuWillOpen(vaults)
        try await Task.sleep(for: .milliseconds(50))

        #expect(places(menu, .vaults).map(\.1) == ["1"])
        #expect(places(menu, .volumes).map(\.1) == [""])
        #expect(menu.items.allSatisfy { $0.keyEquivalent.isEmpty })
    }

    @Test("the placeholder in an empty section is not numbered")
    func placeholderTakesNoDigit() {
        let menu = render([SidebarPlaceGroup(section: .favorites, places: [])])
        let favorites = submenu(menu, .favorites)
        favorites.map { PlacesDigits.hand(to: $0, root: menu) }
        // It has no action, so a digit on it would be a number that does nothing when typed.
        #expect(favorites?.items.first?.keyEquivalent.isEmpty == true)
    }

    @Test("only the first nine are numbered, and the rest carry no digit")
    func numberingStopsAtNine() {
        let many = (1...12).map { index in
            SidebarPlace.vault(
                VaultLocation(imagePath: "/v\(index).sparsebundle", volumeName: "V\(index)")
            )
        }
        let menu = render([SidebarPlaceGroup(section: .vaults, places: many)])
        guard let vaults = submenu(menu, .vaults) else { Issue.record("no Vaults"); return }
        PlacesDigits.hand(to: vaults, root: menu)
        #expect(
            vaults.items.map(\.keyEquivalent) == [
                "1",
                "2",
                "3",
                "4",
                "5",
                "6",
                "7",
                "8",
                "9",
                "",
                "",
                ""
            ]
        )
    }

    @Test("the menu empties when it closes, so its digits are not app-wide shortcuts")
    func closingTheMenuTakesTheDigitsAway() async throws {
        // `Go ▸ Places` is in the menu bar, and `performKeyEquivalent` searches the whole menu bar
        // ahead of `keyDown:`. Measured: with the items an open left behind, a bare "1" fires
        // Recents from anywhere — out from under a rename field — and after this clear it does not.
        let places = PlacesMenu()
        let menu = NSMenu()
        places.build(menu, groups: threeSections)
        PlacesDigits.hand(to: menu, root: menu)
        #expect(!digitsInTree(menu).isEmpty)

        places.menuDidClose(menu)
        try await Task.sleep(for: .milliseconds(50))

        #expect(menu.items.isEmpty)
        #expect(digitsInTree(menu).isEmpty)
    }

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
