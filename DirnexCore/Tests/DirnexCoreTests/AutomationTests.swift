import Foundation
import Testing

@testable import DirnexCore

@Suite("Automation")
struct AutomationTests {
    // MARK: - Verbs

    @Test("every verb has a distinct, non-empty AppleScript command name")
    func verbNamesAreDistinctAndNonEmpty() {
        let names = AutomationVerb.allCases.map(\.commandName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test("the three PLAN verbs are present")
    func verbsCoverThePlan() {
        let cases = Set(AutomationVerb.allCases)
        #expect(cases == [.reveal, .copySelection, .runOperation])
    }

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
}
