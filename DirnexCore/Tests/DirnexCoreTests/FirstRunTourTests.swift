import Foundation
import Testing

@testable import DirnexCore

/// The first-run tour's script (PLAN.md §M7 "First-run tour: palette-centric, 5 screens max"). The
/// tour is data so its shape can be pinned here rather than eyeballed in a running app: it stays
/// short, every action it points at is a real command, and it is palette-centric — the same
/// "the registry is the single source of truth" contract `FunctionBar`'s tests uphold.
@Suite("FirstRunTour")
struct FirstRunTourTests {
    @Test("the tour is non-empty and never longer than PLAN.md's 5-screen ceiling")
    func lengthWithinBudget() {
        #expect(!FirstRunTour.screens.isEmpty)
        #expect(FirstRunTour.screens.count <= FirstRunTour.maximumScreens)
        #expect(FirstRunTour.maximumScreens == 5)
    }

    @Test("every screen has an id, a symbol, a title, and body copy")
    func screensAreWellFormed() {
        for screen in FirstRunTour.screens {
            #expect(!screen.id.isEmpty)
            #expect(!screen.symbol.isEmpty)
            #expect(!screen.title.isEmpty)
            #expect(!screen.body.isEmpty)
        }
    }

    @Test("screen ids are unique, so a test (or a page indicator) can key by them")
    func screenIDsAreUnique() {
        let ids = FirstRunTour.screens.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every highlighted command names a real catalog command")
    func highlightedCommandsResolve() {
        for screen in FirstRunTour.screens {
            for id in screen.commandIDs {
                #expect(
                    CommandCatalog.command(for: id) != nil,
                    "screen \(screen.id) highlights unknown command \(id)"
                )
            }
        }
    }

    /// The load-bearing "palette-centric" claim: the command palette is featured, so the one action
    /// a newcomer must learn to reach everything else is in the tour itself — not just described.
    @Test("the tour features the command palette")
    func featuresCommandPalette() {
        let highlighted = FirstRunTour.screens.flatMap(\.commandIDs)
        #expect(highlighted.contains("view.commandPalette"))
    }

    @Test("the welcome screen leads and introduces the app rather than any one action")
    func welcomeScreenLeads() {
        let first = FirstRunTour.screens.first
        #expect(first?.id == "tour.welcome")
        // The opener sets the scene (dual panels, keyboard-first); it has no command chip to
        // resolve, so a brand-new user isn't asked to parse a shortcut on the very first screen.
        #expect(first?.commandIDs.isEmpty == true)
    }

    /// The tour closes on Full Disk Access — the M7 grant a stranger has to pass to move files
    /// everywhere — so the walkthrough hands straight off to the onboarding it precedes.
    @Test("the final screen points at Full Disk Access")
    func finalScreenPointsAtFullDiskAccess() {
        #expect(FirstRunTour.screens.last?.commandIDs.contains("app.fullDiskAccess") == true)
    }
}
