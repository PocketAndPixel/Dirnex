import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The app layer's side of the function-key bar (PLAN.md §M6). What the slots *are* — the F-key
/// order, the labels, the command ids — is `DirnexCore`'s (`FunctionBar`) and is tested there.
/// What is left here is the wiring that makes a button run something: every slot must resolve to a
/// real AppKit selector (or the button clicks into the void), and the view must build one button
/// per slot with the responder-chain target the dispatch relies on.
@Suite("Function bar view")
@MainActor
struct FunctionBarViewTests {
    /// The load-bearing invariant: a button dispatches `CommandBinding.selector(for:)` down the
    /// responder chain, so a slot whose command has no selector would be a dead button. The core
    /// pins that every slot names a real *catalog* command; this pins that the app has *wired* it.
    @Test("every default slot resolves to a wired command selector")
    func slotsHaveSelectors() {
        for slot in FunctionBar.defaultSlots {
            #expect(
                CommandBinding.selector(for: slot.commandID) != nil,
                "no app selector wired for function-bar slot \(slot.keyName) (\(slot.commandID))"
            )
        }
    }

    @Test("the bar builds one button per slot, each carrying its slot and refusing focus")
    func buttonsMirrorSlots() {
        let slots = FunctionBar.defaultSlots
        let bar = FunctionBarView(slots: slots)
        let buttons = Self.buttons(in: bar)
        #expect(buttons.count == slots.count)
        for (button, slot) in zip(buttons, slots) {
            #expect(button.slot == slot)
            // The bar itself is the target; it forwards the slot to `onRun` (the window controller
            // dispatches to the active pane). A nil-target responder-chain dispatch would miss.
            #expect(button.target != nil)
            // Clicking a button must never pull focus off the pane the command acts on.
            #expect(button.refusesFirstResponder)
        }
    }

    @Test("a `|` divider sits between cells but never after the last one")
    func dividersSitBetweenCells() {
        let slots = FunctionBar.defaultSlots
        let buttons = Self.buttons(in: FunctionBarView(slots: slots))
        for (index, button) in buttons.enumerated() {
            #expect(button.showsTrailingSeparator == (index < buttons.count - 1))
        }
    }

    @Test("clicking a button reports its slot to onRun")
    func clickReportsSlot() {
        let bar = FunctionBarView(slots: FunctionBar.defaultSlots)
        var reported: FunctionBarSlot?
        bar.onRun = { reported = $0 }
        let copyButton = Self.buttons(in: bar).first { $0.slot.commandID == "file.copy" }
        copyButton?.performClick(nil)
        #expect(reported?.commandID == "file.copy")
    }

    // MARK: - User-script slots

    /// The counterpart to `slotsHaveSelectors`, and the reason that test iterates the *default*
    /// slots rather than the whole bar: a user script has no AppKit selector by design — it is
    /// dispatched by recognizing its command-id prefix and running the script. A caller that asks
    /// for a selector first would find `nil` and treat a perfectly good binding as a dead key.
    @Test("a user-script slot has no wired selector and is routed by its id prefix instead")
    func userScriptSlotsRouteByPrefix() {
        let script = UserScript(name: "To PNG", command: "sips", functionKey: 9)
        let slots = FunctionBar.slots(userScripts: [script])
        let slot = FunctionBar.slot(forFunctionKey: 9, in: slots)
        #expect(slot?.commandID == script.commandID)
        #expect(CommandBinding.selector(for: script.commandID) == nil)
        #expect(UserScript.name(fromCommandID: script.commandID) == "To PNG")
    }

    @Test("setSlots rebuilds the row, leaving no orphaned buttons behind")
    func setSlotsRebuildsRow() {
        // The bar is rebuilt live whenever a script's key changes, so a stale button must not
        // survive in the view tree — `removeArrangedSubview` alone would leave it drawn.
        let bar = FunctionBarView(slots: FunctionBar.defaultSlots)
        let script = UserScript(name: "Tidy", command: "tidy", functionKey: 9)
        bar.setSlots(FunctionBar.slots(userScripts: [script]))

        let buttons = Self.buttons(in: bar)
        #expect(buttons.count == FunctionBar.defaultSlots.count + 1)
        #expect(buttons.last?.slot.commandID == script.commandID)
        #expect(buttons.last?.slot.label == "Tidy")
        #expect(bar.subviews.compactMap { $0 as? FunctionBarButton }.isEmpty)

        bar.setSlots(FunctionBar.defaultSlots)
        #expect(Self.buttons(in: bar).count == FunctionBar.defaultSlots.count)
        #expect(!Self.buttons(in: bar).contains { $0.slot.commandID == script.commandID })
    }

    @Test("a rebuilt row's dividers and click reporting still hold for a script slot")
    func rebuiltRowStaysWired() {
        let bar = FunctionBarView(slots: FunctionBar.defaultSlots)
        let script = UserScript(name: "Tidy", command: "tidy", functionKey: 9)
        bar.setSlots(FunctionBar.slots(userScripts: [script]))
        var reported: FunctionBarSlot?
        bar.onRun = { reported = $0 }

        let buttons = Self.buttons(in: bar)
        for (index, button) in buttons.enumerated() {
            #expect(button.showsTrailingSeparator == (index < buttons.count - 1))
        }
        buttons.last?.performClick(nil)
        #expect(reported?.commandID == script.commandID)
    }

    /// The bar's buttons, in row order — walked from the view tree so the view keeps its stack
    /// private.
    private static func buttons(in bar: FunctionBarView) -> [FunctionBarButton] {
        guard let stack = bar.subviews.compactMap({ $0 as? NSStackView }).first else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? FunctionBarButton }
    }
}
