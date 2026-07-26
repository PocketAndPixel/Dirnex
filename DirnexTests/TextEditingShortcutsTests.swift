import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The standard text-editing keys inside every text field in the app — ⌘X, ⌘Z, ⇧⌘Z.
///
/// All three rest on one AppKit fact the compiler cannot check: Cocoa's key bindings map no key to
/// `cut:`, `undo:` or `redo:`, so a field editor sees those chords **only** as a menu key
/// equivalent. Measured both directions — an item carrying `undo:` undoes typing, and the same
/// item carrying any other selector leaves ⌘Z doing nothing at all, however it is validated.
///
/// So each assertion here pins a shortcut that is dead the moment its selector drifts, in a way
/// nothing else notices: the menu still builds, the app still launches, the key just stops working.
/// (The same trap the ⌘A note in docs/NOTES.md records.) `edit.copy` and `edit.paste` are pinned
/// alongside because they work for exactly this reason and are the precedent the other two follow.
@Suite("Text-editing shortcuts")
@MainActor
struct TextEditingShortcutsTests {
    /// Every item in the built main menu, flattened across submenus.
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    @Test("the Edit menu carries a ⌘X Cut item bound to the standard `cut:`")
    func cutItemExists() throws {
        let items = allItems(MainMenuBuilder.build())
        let cut = try #require(items.first { $0.action == #selector(NSText.cut(_:)) })
        #expect(cut.keyEquivalent == "x")
        #expect(cut.keyEquivalentModifierMask == .command)
        // Nil target: the field editor answers `cut:` and no pane does, so it greys itself out
        // everywhere else through the responder chain rather than through a validator.
        #expect(cut.target == nil)
    }

    @Test("undo and redo send the standard selectors, the only ones a field editor sees")
    func undoAndRedoUseStandardSelectors() {
        #expect(CommandBinding.selector(for: "edit.undo") == Selector("undo:"))
        #expect(CommandBinding.selector(for: "edit.redo") == Selector("redo:"))
    }

    @Test("copy and paste keep the standard selectors they already relied on")
    func copyAndPasteUseStandardSelectors() {
        #expect(CommandBinding.selector(for: "edit.copy") == Selector("copy:"))
        #expect(CommandBinding.selector(for: "edit.paste") == Selector("paste:"))
    }

    @Test("the pane implements undo: and redo: itself, so it can route the text case back")
    func paneAnswersTheStandardSelectors() {
        // It must respond — implementing them is what shadows `NSWindow`, which is where the text
        // undo lives; `PanelViewController+Undo` hands that case back when a field editor is up.
        #expect(PanelViewController.instancesRespond(to: Selector("undo:")))
        #expect(PanelViewController.instancesRespond(to: Selector("redo:")))
    }

    @Test("⌘X is not also claimed by a registry command")
    func cutKeyIsUnclaimed() {
        let clash = CommandCatalog.all.first {
            $0.shortcut?.keyEquivalent == "x" && $0.shortcut?.modifiers == .command
        }
        #expect(clash == nil)
    }
}
