import Foundation
import Testing

@testable import DirnexCore

/// The **Go** category of the registry: the history pair, the searches, and the destinations —
/// what a user reaches for when the question is "take me somewhere", rather than "do something to
/// these files".
///
/// Split out of `CommandCatalogTests` when that suite hit SwiftLint's `type_body_length` ceiling
/// (the house rule: at the ceiling, split by *concept* rather than shave lines). The seam is the
/// one the Go menu already draws, and it is where §M20's places command belongs.
@Suite("CommandCatalog: Go")
struct CommandCatalogNavigationTests {
    @Test("the catalog carries the M3 per-panel history commands")
    func coversHistoryCommands() {
        let ids = Set(CommandCatalog.all.map(\.id))
        for expected in ["go.back", "go.forward", "go.history"] {
            #expect(ids.contains(expected))
        }
    }

    @Test("the M5 connect-to-server command is a shortcut-free navigation command")
    func coversConnectServer() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let connect = byID["go.connectServer"]
        #expect(connect?.category == .navigation)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(connect?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "go.connectServer").isEmpty)
    }

    @Test("the M20 places command is a conflict-free navigation command on ⌘G")
    func coversPlaces() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let places = byID["go.places"]
        #expect(places?.category == .navigation)
        #expect(places?.shortcut == CommandShortcut(key: "g", modifiers: .command))
        // It sits beside the favorites popup it generalizes, and must not take its chord.
        #expect(byID["go.favorites"]?.shortcut == CommandShortcut(key: "f", modifiers: .command))
        #expect(KeyBindings().conflicts(for: "go.places").isEmpty)
        #expect(KeyBindings().conflicts(for: "go.favorites").isEmpty)
    }

    @Test("the M6 open-in-terminal command is a shortcut-free navigation command")
    func coversOpenInTerminal() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let open = byID["go.openInTerminal"]
        #expect(open?.category == .navigation)
        // No default shortcut (reached via menu/palette), so it can never collide.
        #expect(open?.shortcut == nil)
        #expect(KeyBindings().conflicts(for: "go.openInTerminal").isEmpty)
    }

    @Test("the M4 file search is a conflict-free Go command on ⌥F7")
    func coversFindFiles() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let search = byID["go.search"]
        #expect(search?.category == .navigation)
        #expect(search?.shortcut == CommandShortcut(key: "F7", modifiers: [.function, .option]))
        // ⌥F7 must not collide with plain F7 (New Folder) — the modifier set differs.
        #expect(KeyBindings().conflicts(for: "go.search").isEmpty)
    }

    @Test("the M4 saved-search command is a conflict-free Go command on ⌘S")
    func coversSaveSearch() {
        let byID = Dictionary(uniqueKeysWithValues: CommandCatalog.all.map { ($0.id, $0) })
        let save = byID["go.saveSearch"]
        #expect(save?.category == .navigation)
        // ⌘S saves the active search; distinct from ⌃⌘S (Show Sidebar), so no collision.
        #expect(save?.shortcut == CommandShortcut(key: "s", modifiers: .command))
        #expect(KeyBindings().conflicts(for: "go.saveSearch").isEmpty)
    }
}
