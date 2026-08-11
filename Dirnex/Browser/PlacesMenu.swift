import AppKit
import DirnexCore

/// **Go ▸ Places** — every destination the sidebar offers, in the menu bar (PLAN.md §M20).
///
/// The sidebar was the only surface that could reach most of them: with it collapsed, Volumes and
/// the cloud mounts were reachable only by typing a path into ⌘L, and saved searches, tags, Recents,
/// the Trash and the merged iCloud listing were not reachable at all. This is the face that is
/// always present whatever the sidebar is doing — the one you can *browse*, rather than having to
/// know what you are looking for.
///
/// This used to claim it also made "Trash" findable through macOS's Help ▸ Search. It does not:
/// **Dirnex declares no Help menu**, so the search field that would index menu items does not exist
/// in this app (checked live 2026-08-12). Nothing rests on it — the ⌘G popup and the path bar's
/// glyph are the other two faces — but it is worth not repeating.
///
/// **It is a rendering of `SidebarPlaces`, not a second list.** The items come from the front
/// window's own `placeSources()` and are dispatched through the same `activate(_:)` the rows go
/// through, so a menu item and a sidebar row cannot come to disagree about what a place is, what it
/// is called, or what opening it does. Two differences from the sidebar are deliberate, and both are
/// about a *table* rather than about the places: a section the user folded shut is still listed
/// here, and Tags lists every tag rather than the stock seven behind an "All Tags…" row.
@MainActor
final class PlacesMenu: NSObject {
    /// The one instance, shared by all three faces (PLAN.md §M20 Slice 3).
    ///
    /// It has to be shared rather than made per caller because `NSMenu.delegate` is **weak**: every
    /// menu below is a fresh, disposable object that fills itself from this delegate, so whatever
    /// owns the delegate has to outlive them all. One instance is also what makes "one funnel, three
    /// faces" true of the object graph and not only of the prose — the menu bar, ⌘G and the path
    /// bar's glyph cannot be handed different builders.
    static let shared = PlacesMenu()

    /// Held strongly because `NSMenu.delegate` is weak and the section submenus point at it.
    let sectionDelegate = PlacesSectionMenuDelegate()

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
    /// nothing, matching what the ⌘F favorites popup has always done.
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
        // Its digits are handed out when it opens and taken back when it closes; see `PlacesDigits`.
        submenu.delegate = sectionDelegate
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
        // The top level's own destinations — Recents and the Trash — hold the digits until the user
        // steps into a section, which takes them (`PlacesDigits`).
        PlacesDigits.hand(to: menu, root: menu)
    }

    /// Empty the menu again once it closes — which is what keeps the bare digits from becoming
    /// **app-wide chords**.
    ///
    /// `Go ▸ Places` lives in the menu bar, and `performKeyEquivalent` searches the whole menu bar
    /// ahead of `keyDown:`, so a bare `1` on an item there is a shortcut that fires from anywhere —
    /// including out from under a rename field. What normally prevents that is that `menuNeedsUpdate`
    /// is *not* called during a key-equivalent search, so a delegate-filled menu is empty to it; but
    /// the items an open leaves behind persist, and they are found. Measured: before the menu has
    /// ever been opened `performKeyEquivalent("1")` is `false`, after one open it is `true` and
    /// jumps to Recents, and after this clear it is `false` again. So the digits exist only while
    /// the menu the user is looking at is open, which is the only time they mean anything.
    ///
    /// Deferred a turn because AppKit sends the chosen item's action *after* the menu closes. The
    /// action survives the clear either way — target and `representedObject` live on the item, which
    /// the dispatch retains — but a detached item is not worth relying on when one hop costs nothing.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { menu.removeAllItems() }
    }
}

/// The bare 1–9 jump keys — the favorites popup's number-key accelerators (Total Commander's), one
/// level up, where the list is a tree rather than a list.
///
/// **Only one menu carries digits at a time: the one the user is looking at.** That is forced rather
/// than chosen, by three things measured on a live menu (2026-08-12):
///
/// 1. An item that carries a **submenu** cannot have a key equivalent at all — AppKit does not draw
///    one (the disclosure chevron owns that space) and `performKeyEquivalent` returns `false` for it,
///    the same finding NOTES.md records for the Go menu's own Places item. So a *section* can never
///    be numbered, only the destinations inside it.
/// 2. The search **recurses into submenus** and fires the first match in menu order, whether or not
///    that submenu is open: with every section numbered from 1, typing `2` at the top level opened
///    the second saved search, two levels down inside a closed submenu.
/// 3. An open submenu is given **no precedence** — with Volumes open and highlighted, `1` still ran
///    the root's Recents, because the root comes first.
///
/// Together those say a digit must be unique across the whole tree at the moment it is typed. Making
/// them unique *statically* would mean one flat 1–9 over the whole menu, which one long section
/// would swallow — leaving the Trash, the last row, permanently unreachable. Handing them to the
/// front menu instead keeps every list numbered from 1, which is what makes it read like the
/// favorites popup rather than like an arbitrary run of numbers.
enum PlacesDigits {
    /// Give `menu` the digits and take them away from everything else under `root`.
    static func hand(to menu: NSMenu, root: NSMenu) {
        strip(from: root)
        var next = 1
        for item in menu.items where isDestination(item) {
            guard next <= 9 else { return }
            item.keyEquivalent = String(next)
            // Bare, with no ⌘: the digit is typed while the menu is open, not as a chord.
            item.keyEquivalentModifierMask = []
            next += 1
        }
    }

    /// Take the digits off `menu` and every menu below it.
    static func strip(from menu: NSMenu) {
        for item in menu.items {
            item.keyEquivalent = ""
            if let submenu = item.submenu { strip(from: submenu) }
        }
    }

    /// A row a digit can actually reach: not a separator, not the disabled "Nothing Here Yet"
    /// placeholder, and not a section header — which is unreachable by key equivalent (1, above),
    /// so numbering one would print a promise AppKit does not keep.
    private static func isDestination(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.submenu == nil && item.action != nil
    }
}

/// Watches the section submenus so the digits follow the user into one and back out again.
///
/// Its own object rather than a second role for `PlacesMenu`, because that class's
/// `menuNeedsUpdate` fills a menu with *the whole places list* — pointed at a section submenu it
/// would refill Volumes with every place there is. `PlacesMenu` holds it strongly:
/// `NSMenu.delegate` is weak, and these submenus are rebuilt on every open.
@MainActor
final class PlacesSectionMenuDelegate: NSObject, NSMenuDelegate {
    /// Bumped by every open, so a close can tell "the user left this section" from "the user moved
    /// to the next one" — AppKit does not promise which of the two callbacks lands first, and
    /// restoring the root's digits while another section is open would let the root win (3, above).
    private var generation = 0

    func menuWillOpen(_ menu: NSMenu) {
        generation += 1
        guard let root = menu.supermenu else { return }
        PlacesDigits.hand(to: menu, root: root)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let root = menu.supermenu else { return }
        let closing = generation
        // A turn later, so an open landing in the same runloop pass has already claimed the digits.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == closing else { return }
            PlacesDigits.hand(to: root, root: root)
        }
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
