import Foundation
import Testing

@testable import DirnexCore

@Suite("Automation")
struct AutomationTests {
    // MARK: - Reveal target

    @Test("revealing a file shows its parent and selects the file")
    func revealFileSelectsInParent() {
        let target = AutomationReveal.target(forPOSIXPath: "/Users/me/notes.txt")
        #expect(target?.container == .local("/Users/me"))
        #expect(target?.item == .local("/Users/me/notes.txt"))
    }

    @Test("revealing a folder still shows it selected in its parent, not entered")
    func revealFolderSelectsInParent() {
        let target = AutomationReveal.target(forPOSIXPath: "/Users/me/Projects")
        #expect(target?.container == .local("/Users/me"))
        #expect(target?.item == .local("/Users/me/Projects"))
    }

    @Test("a trailing slash and doubled slashes normalize to the same target")
    func revealNormalizesSlashes() {
        let plain = AutomationReveal.target(forPOSIXPath: "/Users/me/Projects")
        #expect(AutomationReveal.target(forPOSIXPath: "/Users/me/Projects/") == plain)
        #expect(AutomationReveal.target(forPOSIXPath: "/Users//me/Projects") == plain)
        #expect(AutomationReveal.target(forPOSIXPath: "  /Users/me/Projects  ") == plain)
    }

    @Test("revealing the root shows it with no selection")
    func revealRootHasNoItem() {
        let target = AutomationReveal.target(forPOSIXPath: "/")
        #expect(target?.container == .local("/"))
        #expect(target?.item == nil)
    }

    @Test("a relative or empty path reveals nothing")
    func revealRejectsRelativePaths() {
        #expect(AutomationReveal.target(forPOSIXPath: "me/notes.txt") == nil)
        #expect(AutomationReveal.target(forPOSIXPath: "~/notes.txt") == nil)
        #expect(AutomationReveal.target(forPOSIXPath: "") == nil)
        #expect(AutomationReveal.target(forPOSIXPath: "   ") == nil)
    }

    // MARK: - Operation resolution

    @Test("an exact command id resolves to itself")
    func resolveExactID() {
        #expect(AutomationOperation.resolve("file.copy") == "file.copy")
        #expect(AutomationOperation.resolve("view.terminal") == "view.terminal")
    }

    @Test("a menu title resolves case- and ellipsis-insensitively to its id")
    func resolveByTitle() {
        #expect(AutomationOperation.resolve("Copy to Other Panel") == "file.copy")
        #expect(AutomationOperation.resolve("copy to other panel") == "file.copy")
        // "Rename…" carries a trailing ellipsis in the catalog; a bare "rename" must still hit it.
        #expect(AutomationOperation.resolve("rename") == "file.rename")
        #expect(AutomationOperation.resolve("Rename…") == "file.rename")
    }

    @Test("an unknown operation resolves to nil")
    func resolveUnknown() {
        #expect(AutomationOperation.resolve("not a real command") == nil)
        #expect(AutomationOperation.resolve("") == nil)
        #expect(AutomationOperation.resolve("   ") == nil)
    }

    @Test("a user script resolves by name or by its userScript.* id")
    func resolveUserScript() {
        let script = UserScript(name: "To WebP", command: "cwebp \"$1\"", runMode: .perFile)
        #expect(
            AutomationOperation.resolve("To WebP", userScripts: [script]) == "userScript.To WebP"
        )
        #expect(
            AutomationOperation.resolve("to webp", userScripts: [script]) == "userScript.To WebP"
        )
        #expect(
            AutomationOperation.resolve("userScript.To WebP", userScripts: [script])
                == "userScript.To WebP"
        )
    }

    @Test("a built-in id wins over a user script that happens to share the spelling")
    func builtInWinsOverUserScript() {
        // A user script named exactly like a catalog title shouldn't shadow the real command —
        // commands are matched first, so "New Folder" stays file.newFolder.
        let script = UserScript(name: "New Folder", command: "echo hi")
        #expect(AutomationOperation.resolve("New Folder", userScripts: [script]) == "file.newFolder")
    }

    @Test("resolve defaults to the real catalog so ids stay valid")
    func resolveDefaultsToCatalog() {
        // Guards against a catalog rename silently breaking the scripting surface: these ids must
        // exist for the AppleScript verbs documented in the .sdef to work.
        for id in ["file.copy", "file.move", "file.trash", "file.newFolder", "file.rename"] {
            #expect(AutomationOperation.resolve(id) == id, "\(id) is not a real command")
        }
    }

    // MARK: - Browsing the operation list (the Shortcuts picker)

    private static let webP = UserScript(
        name: "To WebP",
        command: "cwebp \"$1\"",
        runMode: .perFile
    )

    @Test("the operation list is the whole catalog followed by the user's scripts")
    func allListsCatalogThenScripts() {
        let operations = AutomationOperation.all(userScripts: [Self.webP])
        #expect(operations.count == CommandCatalog.all.count + 1)
        #expect(operations.first?.id == CommandCatalog.all.first?.id)
        // The script lands last, carrying the userScript.* id the app routes to the script runner.
        #expect(operations.last?.id == "userScript.To WebP")
        #expect(operations.last?.title == "To WebP")
    }

    @Test("the operation list defaults to the catalog with no scripts")
    func allDefaultsToCatalog() {
        #expect(AutomationOperation.all().map(\.id) == CommandCatalog.all.map(\.id))
    }

    @Test("search ranks a prefix hit first, the way the palette does")
    func searchRanksLikeThePalette() throws {
        let results = AutomationOperation.search("copy to other")
        #expect(results.first?.id == "file.copy")
    }

    @Test("search finds a user script by name")
    func searchFindsUserScripts() {
        let results = AutomationOperation.search("webp", userScripts: [Self.webP])
        #expect(results.first?.id == "userScript.To WebP")
    }

    @Test("an empty search returns the whole list in order — the picker's resting state")
    func searchEmptyReturnsEverything() {
        let all = AutomationOperation.all(userScripts: [Self.webP])
        #expect(AutomationOperation.search("", userScripts: [Self.webP]).map(\.id) == all.map(\.id))
    }

    @Test("a search matching nothing is empty rather than everything")
    func searchUnknownIsEmpty() {
        // The failure mode worth pinning: a picker that falls back to "show all" on a typo looks
        // like it matched.
        #expect(AutomationOperation.search("zzzznotacommand").isEmpty)
    }

    @Test("ids resolve back to operations in the order asked for")
    func operationsPreserveRequestedOrder() {
        let operations = AutomationOperation.operations(
            ids: ["userScript.To WebP", "file.copy"],
            userScripts: [Self.webP]
        )
        #expect(operations.map(\.id) == ["userScript.To WebP", "file.copy"])
    }

    @Test("an id lookup is exact — a title or a stale script id resolves to nothing")
    func operationsMatchIDsExactly() {
        // A saved Shortcut stores an id. Matching a *title* here would let a renamed script bind to
        // whatever else happens to share its spelling, so a title must miss even though `resolve`
        // accepts one.
        #expect(AutomationOperation.operations(ids: ["Copy to Other Panel"]).isEmpty)
        // The renamed/deleted-script case: the id simply stops resolving.
        #expect(AutomationOperation.operations(ids: ["userScript.To WebP"]).isEmpty)
        #expect(AutomationOperation.operations(ids: []).isEmpty)
    }

    @Test("every listed operation resolves back by its own id")
    func everyOperationRoundTrips() {
        // The round trip the Shortcuts picker depends on: whatever the picker offers must still be
        // findable when a saved shortcut runs later.
        let operations = AutomationOperation.all(userScripts: [Self.webP])
        let ids = operations.map(\.id)
        let resolved = AutomationOperation.operations(ids: ids, userScripts: [Self.webP])
        #expect(resolved.map(\.id) == ids)
    }
}
