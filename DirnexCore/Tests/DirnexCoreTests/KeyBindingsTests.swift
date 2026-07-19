import Foundation
import Testing

@testable import DirnexCore

@Suite("KeyBindings")
struct KeyBindingsTests {
    // A pair of real catalog commands with distinct default shortcuts to exercise resolution.
    private let copy = "file.copy" // F5 (fn)
    private let rename = "file.rename" // F2 (fn)

    // MARK: - Resolution

    @Test("an un-customized command resolves to its catalog default")
    func defaultResolution() {
        let bindings = KeyBindings()
        #expect(bindings.shortcut(for: copy) == CommandShortcut(key: "F5", modifiers: .function))
        #expect(bindings.shortcut(for: rename) == CommandShortcut(key: "F2", modifiers: .function))
        #expect(!bindings.isCustomized(copy))
    }

    @Test("a command with no catalog shortcut resolves to nil")
    func noDefault() {
        // select.invert has no shortcut in the catalog.
        #expect(KeyBindings().shortcut(for: "select.invert") == nil)
    }

    @Test("an unknown id resolves to nil rather than trapping")
    func unknownID() {
        #expect(KeyBindings().shortcut(for: "does.not.exist") == nil)
    }

    // MARK: - Mutation

    @Test("rebinding a command overrides its default and marks it customized")
    func rebind() {
        var bindings = KeyBindings()
        let f9 = CommandShortcut(key: "F9", modifiers: .function)
        bindings.setShortcut(f9, for: copy)
        #expect(bindings.shortcut(for: copy) == f9)
        #expect(bindings.isCustomized(copy))
    }

    @Test("binding a command back to its default value drops the override")
    func rebindToDefaultClears() {
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F9", modifiers: .function), for: copy)
        #expect(bindings.isCustomized(copy))
        bindings.setShortcut(CommandShortcut(key: "F5", modifiers: .function), for: copy)
        #expect(!bindings.isCustomized(copy))
        #expect(bindings.overrides[copy] == nil)
    }

    @Test("unbinding strips the shortcut but keeps the command customized")
    func unbind() {
        var bindings = KeyBindings()
        bindings.setShortcut(nil, for: copy)
        #expect(bindings.shortcut(for: copy) == nil)
        #expect(bindings.isCustomized(copy))
        #expect(bindings.overrides[copy] == .unbound)
    }

    @Test("reset removes an override, restoring the default")
    func reset() {
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F9", modifiers: .function), for: copy)
        bindings.reset(copy)
        #expect(!bindings.isCustomized(copy))
        #expect(bindings.shortcut(for: copy) == CommandShortcut(key: "F5", modifiers: .function))
    }

    @Test("resetAll clears every override")
    func resetAll() {
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F9", modifiers: .function), for: copy)
        bindings.setShortcut(nil, for: rename)
        bindings.resetAll()
        #expect(bindings.overrides.isEmpty)
        #expect(bindings == KeyBindings())
    }

    // MARK: - Conflicts

    @Test("the shipped defaults have no shortcut collisions")
    func defaultsAreConflictFree() {
        #expect(!KeyBindings().hasConflicts)
        #expect(KeyBindings().allConflicts().isEmpty)
    }

    @Test("rebinding onto another command's shortcut is reported as a conflict")
    func detectsConflict() {
        var bindings = KeyBindings()
        // Point Copy at Move's F6.
        bindings.setShortcut(CommandShortcut(key: "F6", modifiers: .function), for: copy)
        let copyConflicts = bindings.conflicts(for: copy)
        #expect(copyConflicts == ["file.move"])
        #expect(bindings.conflicts(for: "file.move") == [copy])
        #expect(bindings.hasConflicts)
    }

    @Test("allConflicts groups both commands under the shared shortcut")
    func allConflictsGroups() {
        var bindings = KeyBindings()
        let shared = CommandShortcut(key: "F6", modifiers: .function)
        bindings.setShortcut(shared, for: copy)
        let conflicts = bindings.allConflicts()
        #expect(conflicts.count == 1)
        #expect(conflicts[shared].map(Set.init) == Set([copy, "file.move"]))
    }

    @Test("an unbound command never conflicts")
    func unboundNeverConflicts() {
        var bindings = KeyBindings()
        bindings.setShortcut(nil, for: copy)
        #expect(bindings.conflicts(for: copy).isEmpty)
    }

    // MARK: - Presets

    @Test("the macOS preset is the plain catalog defaults")
    func macOSPreset() {
        #expect(KeyBindings.preset(.macOS) == KeyBindings())
        #expect(KeyBindings.preset(.macOS).overrides.isEmpty)
    }

    @Test("the Total Commander preset rebinds View to F3 and rename to Shift+F6")
    func totalCommanderPreset() {
        let tc = KeyBindings.preset(.totalCommander)
        #expect(
            tc.shortcut(for: "view.quickLook") == CommandShortcut(key: "F3", modifiers: .function)
        )
        #expect(
            tc.shortcut(for: rename) == CommandShortcut(key: "F6", modifiers: [.function, .shift])
        )
        // The shared TC file keys are untouched.
        #expect(tc.shortcut(for: copy) == CommandShortcut(key: "F5", modifiers: .function))
    }

    @Test("both presets are internally conflict-free")
    func presetsConflictFree() {
        for preset in KeyBindings.Preset.allCases {
            #expect(!KeyBindings.preset(preset).hasConflicts, "\(preset) preset has a conflict")
        }
    }

    @Test("matchingPreset identifies a preset and reports Custom after an edit")
    func matchingPreset() {
        #expect(KeyBindings().matchingPreset == .macOS)
        #expect(KeyBindings.preset(.totalCommander).matchingPreset == .totalCommander)

        var custom = KeyBindings.preset(.totalCommander)
        custom.setShortcut(CommandShortcut(key: "F9", modifiers: .function), for: copy)
        #expect(custom.matchingPreset == nil)
    }

    // MARK: - Codable

    @Test("bindings round-trip through JSON, preserving rebinds and unbinds")
    func codableRoundTrip() throws {
        var bindings = KeyBindings()
        bindings.setShortcut(CommandShortcut(key: "F9", modifiers: [.function, .shift]), for: copy)
        bindings.setShortcut(nil, for: rename)

        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)

        #expect(decoded == bindings)
        #expect(
            decoded.shortcut(for: copy) == CommandShortcut(key: "F9", modifiers: [.function, .shift])
        )
        #expect(decoded.shortcut(for: rename) == nil)
    }

    @Test("a plain CommandShortcut round-trips through JSON")
    func shortcutCodable() throws {
        let shortcut = CommandShortcut(key: "s", modifiers: [.command, .control])
        let data = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(CommandShortcut.self, from: data) == shortcut)
    }
}
