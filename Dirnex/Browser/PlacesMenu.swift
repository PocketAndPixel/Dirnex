import AppKit
import DirnexCore

/// **Go ▸ Places** — every destination the sidebar offers, in the menu bar (PLAN.md §M20).
///
/// The sidebar was the only surface that could reach most of them: with it collapsed, Volumes and
/// the cloud mounts were reachable only by typing a path into ⌘L, and saved searches, tags, Recents,
/// the Trash and the merged iCloud listing were not reachable at all. This is the face that is
/// always present whatever the sidebar is doing — and, because macOS's Help ▸ Search searches menu
/// items, it is what makes "Trash" findable by typing the word.
///
/// **It is a rendering of `SidebarPlaces`, not a second list.** The items come from the front
/// window's own `placeSources()` and are dispatched through the same `activate(_:)` the rows go
/// through, so a menu item and a sidebar row cannot come to disagree about what a place is, what it
/// is called, or what opening it does. Two differences from the sidebar are deliberate, and both are
/// about a *table* rather than about the places: a section the user folded shut is still listed
/// here, and Tags lists every tag rather than the stock seven behind an "All Tags…" row.
@MainActor
final class PlacesMenu: NSObject {
    /// The Go-menu item carrying the submenu.
    func menuItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = makeMenu(title: title)
        return item
    }

    /// A fresh, self-populating menu — for the menu bar, and for the pane-level popup and path-bar
    /// glyph that will share it. All of them fill from `menuNeedsUpdate` below, so every face shows
    /// one list built one way.
    ///
    /// **A new `NSMenu` each time, and one long-lived delegate.** An `NSMenu` can be the submenu of
    /// only one item, and `MainMenuBuilder` rebuilds the whole menu bar whenever a key binding or
    /// the language changes — so handing the same menu object to each new Go menu would attach one
    /// that still has a supermenu. `NSMenu.delegate` is weak, which is what makes the reverse
    /// arrangement work: the menus are cheap and disposable, and this object outlives them all
    /// (`MainMenuBuilder` holds the one instance).
    func makeMenu(title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        return menu
    }

    // MARK: - Building

    /// Render `groups` into `menu`: the headerless places bare, each section as a submenu.
    ///
    /// Takes the assembled groups rather than reading them, so the whole rendering is exercisable
    /// from a test without touching the stores — which in a target that runs *inside the app* are
    /// the sidebar the person running the tests is looking at.
    func build(_ menu: NSMenu, groups: [SidebarPlaceGroup], unlockedVaults: Set<String> = []) {
        menu.removeAllItems()
        for group in groups {
            guard let section = group.section else {
                // Recents and the Trash sit bare at the top and bottom, as they do in the sidebar,
                // each set off from the sections between them.
                menu.addItem(.separator())
                for place in group.places {
                    menu.addItem(item(for: place, unlockedVaults: unlockedVaults))
                }
                continue
            }
            menu.addItem(sectionItem(section, group.places, unlockedVaults: unlockedVaults))
        }
        // The separator the leading headerless group added has nothing above it to divide from.
        if menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    }

    /// One section as a submenu. An empty one — which today is only Favorites, whose header survives
    /// because it is the sidebar's drop target — says so in a disabled item rather than opening onto
    /// nothing, matching what the ⌃D favorites popup has always done.
    private func sectionItem(
        _ section: SidebarSection,
        _ places: [SidebarPlace],
        unlockedVaults: Set<String>
    ) -> NSMenuItem {
        let title = LocalizedCatalog.title(for: section)
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        if places.isEmpty {
            let empty = NSMenuItem(
                title: String(
                    localized: "Nothing Here Yet",
                    comment: "Places menu: shown in place of a section that has no entries."
                ),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for place in places {
            submenu.addItem(item(for: place, unlockedVaults: unlockedVaults))
        }
        header.submenu = submenu
        return header
    }

    /// One destination. The place rides in `representedObject` so a store changing while the menu is
    /// open cannot send the user somewhere else — the same reason the favorites popup carries its
    /// path rather than an index.
    ///
    /// `target` stays nil so the action travels the responder chain to the front window's
    /// `BrowserWindowController`: the menu bar is one object shared by every window, and the place
    /// has to open in whichever one the user is looking at.
    private func item(for place: SidebarPlace, unlockedVaults: Set<String>) -> NSMenuItem {
        let item = NSMenuItem(
            title: SidebarPlacePresentation.title(for: place),
            action: #selector(BrowserWindowController.openPlace(_:)),
            keyEquivalent: ""
        )
        item.representedObject = PlaceBox(place)
        item.image = image(for: place, unlockedVaults: unlockedVaults)
        item.toolTip = place.path?.path
        return item
    }

    /// A 16 pt template glyph, the size AppKit draws menu images at — or the tag's colored dot,
    /// which is drawn by the same `TagDotStyle` the sidebar row and the ⌃T menu use.
    private func image(for place: SidebarPlace, unlockedVaults: Set<String>) -> NSImage? {
        if case let .tag(tag) = place {
            return TagDotStyle.menuImage(for: tag.color, diameter: 12)
        }
        guard let symbol = SidebarPlacePresentation.symbolName(
            for: place,
            unlockedVaults: unlockedVaults
        ) else { return nil }
        return SidebarViewController.templateSymbol(
            symbol,
            pointSize: 14,
            describedAs: SidebarPlacePresentation.title(for: place)
        )
    }
}

// MARK: - NSMenuDelegate

extension PlacesMenu: NSMenuDelegate {
    /// Rebuild from the front window every time the submenu opens. Cheap enough to do unconditionally
    /// — the stores are small `UserDefaults` reads and the volume enumeration is the same one the
    /// sidebar already runs on every mount notification — and it is what keeps a server saved a
    /// moment ago from being missing until relaunch.
    ///
    /// With no browser window in front there is nothing to fill it from *and* nothing to dispatch to,
    /// so the menu empties: AppKit then draws it as an empty submenu rather than one whose items all
    /// do nothing.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let window = NSApp.keyWindow?.windowController as? BrowserWindowController else {
            menu.removeAllItems()
            return
        }
        // Which window answers matters only for the vault mount points it has already resolved —
        // every sidebar reads the same shared stores.
        let sidebar = window.sidebar
        build(
            menu,
            groups: SidebarPlaces.groups(from: sidebar.placeSources()),
            unlockedVaults: Set(sidebar.vaultMountPoints.keys)
        )
    }
}

/// A box for the `SidebarPlace` an item carries.
///
/// `representedObject` is `Any?`, so a bare enum survives the round trip — but reading it back needs
/// a conditional cast to a *concrete* type, and boxing it in a class keeps that cast from silently
/// becoming an existential the day `SidebarPlace` grows a generic parameter or a protocol
/// conformance. It also makes the menu's payload greppable.
final class PlaceBox: NSObject {
    let place: SidebarPlace

    init(_ place: SidebarPlace) {
        self.place = place
    }
}
