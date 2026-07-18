import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's side of the first-run tour (PLAN.md §M7). What the tour *says* — the screens,
/// their order, and that each names a real catalog command — is `DirnexCore.FirstRunTour`'s and is
/// tested there. What is left here is the wiring: the "Welcome to Dirnex…" command must dispatch a
/// real selector, and every action the tour holds up as "you can do this" must actually be runnable,
/// or the reference would point at something the app can't perform.
@Suite("First-run tour view")
@MainActor
struct FirstRunTourViewTests {
    @Test("the show-tour command resolves to a wired app selector")
    func showTourCommandIsWired() {
        #expect(CommandBinding.selector(for: "app.showTour") != nil)
    }

    /// The counterpart of the function bar's `slotsHaveSelectors`: a screen highlights a command by
    /// id, and the app resolves it to a title-plus-shortcut chip. Every one must be a real, wired
    /// command — both so the chip renders and so the claim it makes ("copy", "connect", "grant
    /// access") is one the app can honour.
    @Test("every highlighted command is a real, dispatchable command")
    func highlightedCommandsAreDispatchable() {
        for id in FirstRunTour.screens.flatMap(\.commandIDs) {
            #expect(
                CommandCatalog.command(for: id) != nil,
                "tour highlights unknown command \(id)"
            )
            #expect(
                CommandBinding.selector(for: id) != nil,
                "tour highlights command \(id) with no wired selector"
            )
        }
    }

    /// The chips print the *effective* shortcut through the user's bindings, the same glyph the menu
    /// shows — so the palette screen advertises whatever ⌘K is currently bound to (its default here).
    @Test("the palette screen's command resolves to a printable shortcut")
    func paletteShortcutResolves() {
        #expect(KeyBindingStore.shared.shortcut(for: "view.commandPalette")?.display == "⌘K")
    }

    @Test("the controller builds a window and takes an on-demand final-button title")
    func controllerBuildsWindow() {
        let controller = FirstRunTourWindowController()
        #expect(controller.window != nil)
        // The on-demand path retitles the last screen's primary button; the launch path leaves the
        // default. Both must be settable before presentation.
        controller.finalButtonTitle = "Open Command Palette"
        #expect(controller.finalButtonTitle == "Open Command Palette")
    }
}
