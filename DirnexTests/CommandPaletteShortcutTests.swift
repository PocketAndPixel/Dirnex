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
