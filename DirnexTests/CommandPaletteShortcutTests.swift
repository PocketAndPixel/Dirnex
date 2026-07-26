import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// How the ⌘K palette decides which shortcut to print beside a row (PLAN.md §M3/§M6).
///
/// The distinction under test is easy to lose and invisible to the compiler: `KeyBindings` resolves
/// an un-overridden id by looking it up in `CommandCatalog`, so it answers `nil` for *any* command
/// that isn't in the registry — including a user script, whose F-key binding lives on the script.
/// Asking it alone silently drops the key from the palette (caught on screen, not by a test); always
/// falling back to `Command.shortcut` instead would resurrect a shortcut the user deliberately
/// unbound. Both halves are pinned here.
@Suite("Command palette shortcuts")
@MainActor
struct CommandPaletteShortcutTests {
    @Test("a user script's own function key is advertised")
    func userScriptShortcutIsShown() {
        let palette = CommandPaletteController()
        let bound = UserScript(name: "To PNG", command: "sips", functionKey: 9)
        #expect(palette.shortcut(for: bound.paletteCommand)?.display == "F9")
    }

    @Test("an unbound user script advertises nothing")
    func unboundUserScriptHasNoShortcut() {
        let palette = CommandPaletteController()
        let plain = UserScript(name: "Plain", command: "echo")
        #expect(palette.shortcut(for: plain.paletteCommand) == nil)
    }

    @Test("a catalog command still resolves through the user's bindings, not its own default")
    func catalogCommandsGoThroughBindings() throws {
        let palette = CommandPaletteController()
        let copy = try #require(CommandCatalog.command(for: "file.copy"))
        #expect(palette.shortcut(for: copy) == KeyBindingStore.shared.shortcut(for: "file.copy"))
    }
}

/// How the palette's result list answers the mouse (PLAN.md §M3).
///
/// Both facts here fail in the quiet direction and neither is visible to the compiler. The search
/// field is the palette's only key handler — `control(_:doCommandBy:)` owns ⎋, ⏎ and ↑/↓ — so a
/// list that accepts first responder silently kills every one of them on the first click, which is
/// exactly what shipped: typing went nowhere, ⏎ ran nothing and ⎋ did not close the panel, with the
/// selection turning blue as the only tell.
@Suite("Command palette list")
@MainActor
struct CommandPaletteListTests {
    @Test("the result list never takes the keyboard from the search field")
    func listRefusesFirstResponder() {
        #expect(CommandPaletteTableView().acceptsFirstResponder == false)
    }

    /// Opens the real panel rather than reaching for the private configuration step, so the test
    /// fails if the wiring stops being applied as well as if it changes.
    ///
    /// `doubleAction` is asserted equal to `action` rather than to `nil`: `NSTableView` mirrors the
    /// two and refuses to clear the mirror, so `nil` is unreachable and the invariant that is worth
    /// pinning is that no *distinct* double-click behavior was ever introduced behind the click.
    @Test("a single click runs the row, with no separate double-click behavior")
    func singleClickRunsTheRow() {
        let palette = CommandPaletteController()
        palette.toggle(over: nil)
        defer { palette.dismiss() }
        #expect(palette.tableView.action == Selector(("rowClicked")))
        #expect(palette.tableView.doubleAction == palette.tableView.action)
    }
}
