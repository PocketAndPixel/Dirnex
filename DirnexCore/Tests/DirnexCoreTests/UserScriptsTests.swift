import Foundation
import Testing

@testable import DirnexCore

@Suite("UserScripts")
struct UserScriptsTests {
    private func script(_ name: String, _ command: String = ":") -> UserScript {
        UserScript(name: name, command: command)
    }

    @Test("save appends a new script and reports it as new")
    func saveAppendsNew() {
        var scripts = UserScripts()
        let replaced = scripts.save(script("To WebP"))
        #expect(replaced == false)
        #expect(scripts.scripts.map(\.name) == ["To WebP"])
    }

    @Test("save overwrites a same-named script in place, keeping its position")
    func saveOverwritesInPlace() {
        var scripts = UserScripts(scripts: [script("A"), script("B"), script("C")])
        let replaced = scripts.save(UserScript(name: "B", command: "echo new"))
        #expect(replaced == true)
        #expect(scripts.scripts.map(\.name) == ["A", "B", "C"])
        #expect(scripts.script(named: "B")?.command == "echo new")
    }

    @Test("the initializer collapses duplicate names, keeping the first")
    func initializerDedupes() {
        let scripts = UserScripts(scripts: [
            UserScript(name: "Dup", command: "first"),
            UserScript(name: "Dup", command: "second"),
            script("Other")
        ])
        #expect(scripts.scripts.map(\.name) == ["Dup", "Other"])
        #expect(scripts.script(named: "Dup")?.command == "first")
    }

    @Test("remove by name deletes when present and reports whether it did")
    func removeByName() {
        var scripts = UserScripts(scripts: [script("A"), script("B")])
        #expect(scripts.remove(name: "A") == true)
        #expect(scripts.remove(name: "missing") == false)
        #expect(scripts.scripts.map(\.name) == ["B"])
    }

    @Test("remove at index ignores an out-of-range index")
    func removeAtIndex() {
        var scripts = UserScripts(scripts: [script("A"), script("B")])
        scripts.remove(at: 5)
        #expect(scripts.scripts.count == 2)
        scripts.remove(at: 0)
        #expect(scripts.scripts.map(\.name) == ["B"])
    }

    @Test("rename changes the name but rejects empty or colliding targets")
    func rename() {
        var scripts = UserScripts(scripts: [script("A"), script("B")])
        #expect(scripts.rename(name: "A", to: "Alpha") == true)
        #expect(scripts.scripts.map(\.name) == ["Alpha", "B"])
        // Empty target rejected.
        #expect(scripts.rename(name: "Alpha", to: "") == false)
        // Colliding with a different script rejected — never collapse two into one.
        #expect(scripts.rename(name: "Alpha", to: "B") == false)
        // Renaming to the same name is a no-op success.
        #expect(scripts.rename(name: "B", to: "B") == true)
        #expect(scripts.scripts.map(\.name) == ["Alpha", "B"])
    }

    @Test("move reorders with Array insertion semantics")
    func move() {
        var scripts = UserScripts(scripts: [script("A"), script("B"), script("C")])
        scripts.move(from: 0, to: 2)
        #expect(scripts.scripts.map(\.name) == ["B", "C", "A"])
    }

    @Test("paletteCommands mirrors the scripts in order")
    func paletteCommands() {
        let scripts = UserScripts(scripts: [script("A"), script("B")])
        #expect(scripts.paletteCommands.map(\.id) == ["userScript.A", "userScript.B"])
        #expect(scripts.paletteCommands.map(\.title) == ["A", "B"])
    }

    @Test("the collection round-trips through JSON, sanitizing duplicates on decode")
    func codableRoundTrip() throws {
        let scripts = UserScripts(scripts: [
            UserScript(name: "One", command: "a", runMode: .perFile, keywords: ["x"]),
            script("Two", "b")
        ])
        let data = try JSONEncoder().encode(scripts)
        let decoded = try JSONDecoder().decode(UserScripts.self, from: data)
        #expect(decoded == scripts)

        // A hand-edited store with a duplicate name is sanitized on the way back in.
        let dupJSON = #"{"scripts":[{"name":"D","command":"a","runMode":"combined","keywords":[]},"#
            + #"{"name":"D","command":"b","runMode":"combined","keywords":[]}]}"#
        let sanitized = try JSONDecoder().decode(UserScripts.self, from: Data(dupJSON.utf8))
        #expect(sanitized.scripts.count == 1)
        #expect(sanitized.script(named: "D")?.command == "a")
    }
}
