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

    @Test("slot(forFunctionKey:) finds a mapped key and misses an unmapped one")
    func lookupByFunctionKey() {
        #expect(FunctionBar.slot(forFunctionKey: 5)?.commandID == "file.copy")
        #expect(FunctionBar.slot(forFunctionKey: 3)?.commandID == "view.quickLook")
        // F4 is deliberately unbound (Dirnex has no "edit" command), so a press falls through.
        #expect(FunctionBar.slot(forFunctionKey: 4) == nil)
    }

    @Test("F5–F8 map to their canonical operations in Total Commander's order")
    func canonicalKeyMapping() {
        #expect(FunctionBar.slot(forFunctionKey: 5)?.label == "Copy")
        #expect(FunctionBar.slot(forFunctionKey: 6)?.label == "Move")
        #expect(FunctionBar.slot(forFunctionKey: 7)?.commandID == "file.newFolder")
        #expect(FunctionBar.slot(forFunctionKey: 8)?.commandID == "file.trash")
    }

    @Test("a slot round-trips through Codable so a saved layout reads back")
    func codableRoundTrip() throws {
        let slot = FunctionBarSlot(functionKey: 8, label: "Delete", commandID: "file.trash")
        let data = try JSONEncoder().encode(slot)
        let decoded = try JSONDecoder().decode(FunctionBarSlot.self, from: data)
        #expect(decoded == slot)
    }
}
