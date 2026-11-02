import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Opening a place from **⌘G**, the path bar's glyph or Go ▸ Places in a new tab: a ⌘-click, ⌘Return,
/// or ⌘ and the place's digit, as a ⌘-click on its sidebar row does.
///
/// Each destination is followed by a ⌘ *alternate*, which AppKit picks in its place while ⌘ is held
/// (`PlacesMenu`). What is pinned here is the half this target can reach: the pair is built so AppKit
/// can tell its two items apart, the digits follow both, and a ⌘ chord fires the alternate. Whether
/// the menu picks the alternate for a ⌘-click or ⌘Return was measured in a probe menu, and the window
/// action that follows was verified in the running app. The sidebar's routing of the request to the
/// window is `SidebarNewTabTests`'.
@Suite("Places menu opens in a new tab")
@MainActor
struct PlacesMenuNewTabTests {
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

    private var groups: [SidebarPlaceGroup] {
        [
            SidebarPlaceGroup(section: nil, places: [.recents]),
            SidebarPlaceGroup(section: .volumes, places: [.volume(volume)]),
            SidebarPlaceGroup(section: nil, places: [.trash])
        ]
    }

    private func render() -> NSMenu {
        let menu = NSMenu()
        PlacesMenu().build(menu, groups: groups)
        return menu
    }

    private func volumes(_ menu: NSMenu) throws -> NSMenu {
        try #require(
            menu.items.first { $0.title == LocalizedCatalog.title(for: .volumes) }?.submenu
        )
    }

    /// Not a separator or a section header — which AppKit gives an action of its own,
    /// `submenuAction:`, so an action alone does not tell a destination.
    private func isDestination(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.submenu == nil
    }

    /// Every key chord in the tree, a ⌘ alternate's written with its ⌘.
    private func chords(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            let command = item.keyEquivalentModifierMask.contains(.command) ? "⌘" : ""
            let own = item.keyEquivalent.isEmpty ? [] : [command + item.keyEquivalent]
            return own + (item.submenu.map(chords) ?? [])
        }
    }

    @Test("every destination is followed by a ⌘ alternate that opens it in a new tab")
    func everyDestinationHasANewTabAlternate() throws {
        let menu = render()
        // By name, as `PlacesMenuTests` asserts `openPlace:`: a `#selector` would go on naming the
        // method after the window controller stopped implementing it.
        let opensInNewTab = NSSelectorFromString("openPlaceInNewTab:")
        #expect(BrowserWindowController.instancesRespond(to: opensInNewTab))

        let destinations = try menu.items.filter(isDestination) + volumes(menu).items
        #expect(destinations.count == 6)
        for index in stride(from: 0, to: destinations.count - 1, by: 2) {
            let opens = destinations[index]
            let alternate = destinations[index + 1]
            #expect(opens.action == NSSelectorFromString("openPlace:"))
            #expect(!opens.isAlternate)
            #expect(alternate.action == opensInNewTab)
            #expect(alternate.isAlternate)
            // Nil, as the item's own: the menu bar is shared by every window.
            #expect(alternate.target == nil)
            #expect(alternate.title == opens.title)
            let place = (alternate.representedObject as? PlaceBox)?.place
            #expect(place == (opens.representedObject as? PlaceBox)?.place)
            // AppKit tells an alternate from its item by the mask alone, and an item's default mask
            // is ⌘, so leaving the drawn item's at its default would make the two identical.
            #expect(opens.keyEquivalentModifierMask == [])
            #expect(alternate.keyEquivalentModifierMask == .command)
        }
    }

    @Test("an alternate takes its item's digit, wherever the digits are")
    func alternatesShareTheirDigit() throws {
        let menu = render()
        PlacesDigits.hand(to: menu, root: menu)
        #expect(chords(menu) == ["1", "⌘1", "2", "⌘2"])

        let volumes = try volumes(menu)
        PlacesMenu().sectionDelegate.menuWillOpen(volumes)
        #expect(chords(menu) == ["1", "⌘1"])
        #expect(volumes.items.map(\.keyEquivalent) == ["1", "1"])
        // Stripped, the root's pairs keep their masks, so they still pair with no digit at all.
        #expect(menu.items.filter(\.isAlternate).allSatisfy {
            $0.keyEquivalentModifierMask == .command
        })
    }

    @Test("⌘ and a digit fires the alternate, and the digit alone the item drawn")
    func commandDigitOpensInANewTab() throws {
        let menu = render()
        PlacesDigits.hand(to: menu, root: menu)
        // The real items reach the window through the responder chain, which a menu with no window
        // does not have, so the recorder stands in for the window.
        let recorder = PlaceActionRecorder()
        for item in menu.items where isDestination(item) {
            item.target = recorder
        }

        #expect(try menu.performKeyEquivalent(with: digit("2", .command)))
        #expect(try menu.performKeyEquivalent(with: digit("1", [])))
        #expect(recorder.picks == [
            "new tab \(SidebarPlacePresentation.title(for: .trash))",
            SidebarPlacePresentation.title(for: .recents)
        ])
    }

    private func digit(_ key: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: key == "1" ? 18 : 19
        ))
    }
}

/// Records which of the two Places actions a menu item fired, and for which place.
@MainActor
private final class PlaceActionRecorder: NSObject {
    var picks: [String] = []

    private func title(_ sender: Any?) -> String {
        guard let place = ((sender as? NSMenuItem)?.representedObject as? PlaceBox)?.place else {
            return "?"
        }
        return SidebarPlacePresentation.title(for: place)
    }

    @objc func openPlace(_ sender: Any?) {
        picks.append(title(sender))
    }

    @objc func openPlaceInNewTab(_ sender: Any?) {
        picks.append("new tab \(title(sender))")
    }
}
