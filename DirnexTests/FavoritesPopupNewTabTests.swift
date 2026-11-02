import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Opening a pin from the **⌘F** popup in a new tab: a ⌘-click, ⌘Return, or ⌘ and the pin's digit,
/// as from its sidebar row and from ⌘G.
///
/// It is built the way ⌘G's is (`PlacesMenuNewTabTests`): each pin is followed by a ⌘ alternate,
/// which AppKit picks in its place while ⌘ is held. Pinned here: the pair is built so AppKit can tell
/// its two items apart, and a ⌘ chord fires the alternate. What `jumpToFavorite(_:inNewTab:)` puts on
/// the new tab is `SidebarNewTabTests`'. The list is handed in, so nothing reads the developer's pins.
@Suite("Favorites popup opens in a new tab")
@MainActor
struct FavoritesPopupNewTabTests {
    private let work = FavoriteEntry(path: .local("/Users/u/Work"))
    private let music = FavoriteEntry(path: .local("/Users/u/Music"))

    /// The view is never loaded, so nothing lists.
    private func pane() -> PanelViewController {
        let here = VFSPath.local(NSTemporaryDirectory())
        let vc = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: here,
            restorationKey: nil
        )
        vc.panel = Panel(path: here)
        return vc
    }

    private func jumps(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { $0.representedObject is FavoriteEntry }
    }

    @Test("every pin is followed by a ⌘ alternate that opens it in a new tab")
    func everyPinHasANewTabAlternate() {
        let pane = pane()
        let items = jumps(pane.favoritesMenu(for: Favorites(entries: [work, music])))
        // By name: a `#selector` would go on naming the method after the pane stopped implementing
        // it (docs/NOTES.md).
        let jumpsInNewTab = NSSelectorFromString("jumpToFavoriteEntryInNewTab:")
        #expect(PanelViewController.instancesRespond(to: jumpsInNewTab))

        #expect(items.count == 4)
        for (index, entry) in [work, music].enumerated() {
            let jump = items[2 * index]
            let alternate = items[2 * index + 1]
            #expect(jump.action == NSSelectorFromString("jumpToFavoriteEntry:"))
            #expect(!jump.isAlternate)
            #expect(alternate.action == jumpsInNewTab)
            #expect(alternate.isAlternate)
            #expect(alternate.target === pane)
            #expect(alternate.title == jump.title)
            #expect(jump.representedObject as? FavoriteEntry == entry)
            #expect(alternate.representedObject as? FavoriteEntry == entry)
            // AppKit pairs the two by key equivalent and tells them apart by mask alone.
            #expect(jump.keyEquivalent == String(index + 1))
            #expect(alternate.keyEquivalent == jump.keyEquivalent)
            #expect(jump.keyEquivalentModifierMask == [])
            #expect(alternate.keyEquivalentModifierMask == .command)
        }
    }

    @Test("past nine a pin has no digit, and its alternate still pairs by mask")
    func pinsPastNineStillPair() {
        let entries = (1...10).map { FavoriteEntry(path: .local("/Users/u/F\($0)")) }
        let items = jumps(pane().favoritesMenu(for: Favorites(entries: entries)))
        #expect(items.count == 20)
        let tenth = items[18]
        let tenthInNewTab = items[19]
        #expect(tenth.keyEquivalent.isEmpty)
        #expect(tenthInNewTab.keyEquivalent.isEmpty)
        #expect(tenthInNewTab.isAlternate)
        #expect(tenth.keyEquivalentModifierMask == [])
        #expect(tenthInNewTab.keyEquivalentModifierMask == .command)
    }

    @Test("with nothing pinned there is the placeholder and no alternate")
    func emptyListHasNoAlternate() {
        let menu = pane().favoritesMenu(for: Favorites())
        #expect(menu.items.first?.isEnabled == false)
        let hasAlternate = menu.items.contains { $0.isAlternate }
        #expect(!hasAlternate)
    }

    @Test("⌘ and a digit fires the alternate, and the digit alone the pin's own item")
    func commandDigitOpensInANewTab() throws {
        let menu = pane().favoritesMenu(for: Favorites(entries: [work, music]))
        // The real target is the pane, whose jump would list and focus a table; the recorder stands
        // in for it.
        let recorder = FavoriteJumpRecorder()
        for item in jumps(menu) {
            item.target = recorder
        }

        #expect(try menu.performKeyEquivalent(with: digit("2", .command)))
        #expect(try menu.performKeyEquivalent(with: digit("1", [])))
        #expect(recorder.jumps == ["new tab \(music.name)", work.name])
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

/// Records which of the popup's two jump actions a menu item fired, and for which pin.
@MainActor
private final class FavoriteJumpRecorder: NSObject {
    var jumps: [String] = []

    private func name(_ sender: NSMenuItem) -> String {
        (sender.representedObject as? FavoriteEntry)?.name ?? "?"
    }

    @objc func jumpToFavoriteEntry(_ sender: NSMenuItem) {
        jumps.append(name(sender))
    }

    @objc func jumpToFavoriteEntryInNewTab(_ sender: NSMenuItem) {
        jumps.append("new tab \(name(sender))")
    }
}
