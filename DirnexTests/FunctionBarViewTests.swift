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

    @Test("clicking a button reports its slot to onRun")
    func clickReportsSlot() {
        let bar = FunctionBarView(slots: FunctionBar.defaultSlots)
        var reported: FunctionBarSlot?
        bar.onRun = { reported = $0 }
        let copyButton = Self.buttons(in: bar).first { $0.slot.commandID == "file.copy" }
        copyButton?.performClick(nil)
        #expect(reported?.commandID == "file.copy")
    }

    /// The bar's buttons, in row order — walked from the view tree so the view keeps its stack
    /// private.
    private static func buttons(in bar: FunctionBarView) -> [FunctionBarButton] {
        guard let stack = bar.subviews.compactMap({ $0 as? NSStackView }).first else { return [] }
        return stack.arrangedSubviews.compactMap { $0 as? FunctionBarButton }
    }
}
