import Foundation
import Testing

@testable import DirnexCore

@Suite("FunctionBar")
struct FunctionBarTests {
    @Test("a slot prints its key as F<n>")
    func keyName() {
        #expect(
            FunctionBarSlot(functionKey: 5, label: "Copy", commandID: "file.copy").keyName == "F5"
        )
        #expect(FunctionBarSlot(functionKey: 12, label: "X", commandID: "x").keyName == "F12")
    }

    @Test("the default bar is non-empty and every slot names a real catalog command")
    func defaultSlotsResolveToCatalogCommands() {
        let slots = FunctionBar.defaultSlots
        #expect(!slots.isEmpty)
        for slot in slots {
            #expect(!slot.label.isEmpty)
            #expect(
                CommandCatalog.command(for: slot.commandID) != nil,
                "slot \(slot.keyName) points at unknown command \(slot.commandID)"
            )
        }
    }

    @Test("the default bar carries the four core file operations")
    func defaultSlotsCoverCoreOperations() {
        let commandIDs = Set(FunctionBar.defaultSlots.map(\.commandID))
        for expected in ["file.copy", "file.move", "file.newFolder", "file.trash"] {
            #expect(commandIDs.contains(expected))
        }
    }

    @Test("no two slots claim the same function key")
    func functionKeysAreUnique() {
        let keys = FunctionBar.defaultSlots.map(\.functionKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test("slot(forFunctionKey:in:) finds a mapped key and misses an unmapped one")
    func lookupByFunctionKey() {
        let slots = FunctionBar.defaultSlots
        #expect(FunctionBar.slot(forFunctionKey: 5, in: slots)?.commandID == "file.copy")
        #expect(FunctionBar.slot(forFunctionKey: 3, in: slots)?.commandID == "view.quickLook")
        // F4 is Edit since §M11 — the last key on the Total Commander row to be bound.
        #expect(FunctionBar.slot(forFunctionKey: 4, in: slots)?.commandID == "file.edit")
        // F9 carries nothing on a stock bar, so a press falls through untouched.
        #expect(FunctionBar.slot(forFunctionKey: 9, in: slots) == nil)
    }

    @Test("F5–F8 map to their canonical operations in Total Commander's order")
    func canonicalKeyMapping() {
        let slots = FunctionBar.defaultSlots
        #expect(FunctionBar.slot(forFunctionKey: 4, in: slots)?.label == "Edit")
        #expect(FunctionBar.slot(forFunctionKey: 5, in: slots)?.label == "Copy")
        #expect(FunctionBar.slot(forFunctionKey: 6, in: slots)?.label == "Move")
        #expect(FunctionBar.slot(forFunctionKey: 7, in: slots)?.commandID == "file.newFolder")
        #expect(FunctionBar.slot(forFunctionKey: 8, in: slots)?.commandID == "file.trash")
    }

    @Test("a slot round-trips through Codable so a saved layout reads back")
    func codableRoundTrip() throws {
        let slot = FunctionBarSlot(functionKey: 8, label: "Delete", commandID: "file.trash")
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(FunctionBarSlot.self, from: data)
        #expect(decoded == slot)
    }

    // MARK: - User-script bindings

    @Test("every key a command claims with a bare F-key menu equivalent is reserved")
    func reservedCoversBareMenuEquivalents() {
        let reserved = FunctionBar.reservedFunctionKeys()
        // A menu key-equivalent is dispatched before keyDown ever reaches the pane, so a script
        // on one of these would run from its button and stay dead on the key — the asymmetry the
        // whole reserved set exists to prevent.
        for expected in [2, 4, 5, 6, 7, 8] {
            #expect(reserved.contains(expected), "F\(expected) has a menu equivalent")
        }
    }

    @Test("the built-in bar's own keys are reserved, so a script can't displace View")
    func reservedCoversDefaultSlots() {
        let reserved = FunctionBar.reservedFunctionKeys()
        for slot in FunctionBar.defaultSlots {
            #expect(reserved.contains(slot.functionKey))
        }
        // F3 has no menu equivalent by default — it is reserved purely as a built-in bar slot.
        #expect(reserved.contains(3))
    }

    @Test("a modified F-key shortcut does not reserve the bare key")
    func modifiedShortcutsDoNotReserve() {
        // ⌥F5 (queue copy) and ⇧F8 (delete now) exist in the catalog; neither is the bare key's
        // equivalent, so neither can swallow a bare press.
        var bindings = KeyBindings()
        bindings.setShortcut(
            CommandShortcut(key: "F9", modifiers: [.function, .shift]),
            for: "file.copy"
        )
        #expect(!FunctionBar.reservedFunctionKeys(bindings: bindings).contains(9))
    }

    @Test("the assignable keys are the free ones, and exclude macOS's own F11")
    func assignableKeys() {
        let assignable = FunctionBar.assignableFunctionKeys()
        // F4 left this set in §M11, when it became Edit.
        #expect(assignable == [1, 9, 10, 12])
        // F11 is Show Desktop system-wide — the WindowServer eats it before Dirnex is asked.
        #expect(!assignable.contains(11))
    }

    @Test("rebinding a command onto a free key reserves it; freeing one returns it")
    func reservedFollowsBindings() {
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F9", modifiers: .function), for: "file.copy")
        #expect(FunctionBar.reservedFunctionKeys(bindings: bindings).contains(9))
        #expect(!FunctionBar.assignableFunctionKeys(bindings: bindings).contains(9))
        // The Total Commander preset moves rename off bare F2 onto ⇧F6 — but F2 stays reserved,
        // because the built-in bar still prints it.
        let tc = KeyBindings.preset(.totalCommander)
        #expect(FunctionBar.reservedFunctionKeys(bindings: tc).contains(2))
        #expect(FunctionBar.reservedFunctionKeys(bindings: tc).contains(3))
    }

    @Test("a bound script joins the bar in key order and dispatches its own command id")
    func scriptSlotsMerge() {
        let scripts = [
            UserScript(name: "To PNG", command: "sips", functionKey: 9),
            UserScript(name: "Notes", command: "cat"), // unbound — palette only
            UserScript(name: "Tidy", command: "tidy", functionKey: 10)
        ]
        let slots = FunctionBar.slots(userScripts: scripts)
        #expect(slots.map(\.functionKey) == [2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(FunctionBar.slot(forFunctionKey: 9, in: slots)?.commandID == "userScript.To PNG")
        #expect(FunctionBar.slot(forFunctionKey: 9, in: slots)?.label == "To PNG")
        #expect(FunctionBar.slot(forFunctionKey: 10, in: slots)?.label == "Tidy")
        // The unbound script contributes no button.
        #expect(!slots.contains { $0.commandID == "userScript.Notes" })
    }

    @Test("a script holding a reserved key is skipped, not honoured")
    func scriptOnReservedKeyIsSkipped() {
        // F5 is Copy's menu equivalent; F11 belongs to macOS. Neither may be taken, however the
        // store came to hold it (a preset switch, or a hand edit).
        let scripts = [
            UserScript(name: "Hijack", command: "x", functionKey: 5),
            UserScript(name: "Desktop", command: "y", functionKey: 11)
        ]
        let slots = FunctionBar.slots(userScripts: scripts)
        #expect(slots == FunctionBar.defaultSlots)
        #expect(FunctionBar.slot(forFunctionKey: 5, in: slots)?.commandID == "file.copy")
    }

    @Test("a script's key survives a preset that reserves it, and comes back when it frees it")
    func skippedScriptKeepsItsKey() {
        // The point of skipping at merge rather than validating at save: the reserved set is user
        // state that moves, so a binding must not be destroyed by a preset switch.
        let script = UserScript(name: "Preview", command: "qlmanage", functionKey: 10)
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F10", modifiers: .function), for: "file.copy")
        #expect(!FunctionBar.slots(userScripts: [script], bindings: bindings).contains {
            $0.commandID == script.commandID
        })
        // The script never changed — with the key free again its button returns.
        #expect(
            FunctionBar.slots(userScripts: [script]).contains { $0.commandID == script.commandID }
        )
    }

    @Test("a script left on a key a command has since taken is reported as displaced")
    func displacedScriptsAreNamed() {
        // The F4 case §M11 creates: a key that was assignable in the previous build and is Edit's
        // in this one. The script still runs from the palette — it is only the *key* that is gone.
        let scripts = [
            UserScript(name: "Tidy", command: "tidy", functionKey: 4),
            UserScript(name: "To PNG", command: "sips", functionKey: 9),
            UserScript(name: "Notes", command: "cat"),
            UserScript(name: "Desktop", command: "y", functionKey: 11)
        ]
        let displaced = FunctionBar.displacedScripts(scripts)
        #expect(displaced.map(\.name) == ["Tidy", "Desktop"])
    }

    @Test("nothing is displaced when every bound script holds an assignable key")
    func nothingDisplacedOnAHealthyStore() {
        let scripts = [
            UserScript(name: "To PNG", command: "sips", functionKey: 9),
            UserScript(name: "Notes", command: "cat")
        ]
        #expect(FunctionBar.displacedScripts(scripts).isEmpty)
    }
}
