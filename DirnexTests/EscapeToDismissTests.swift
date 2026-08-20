import AppKit
import Testing

@testable import Dirnex

/// Escape's binding on the app's alerts.
///
/// This exists because `NSAlert` binds Escape itself — but it matches the **byte string "Cancel"**,
/// not a localized one. Probed with the process pinned to `ru`, a button titled «Отмена» is given no
/// key equivalent at all, so under any translation AppKit's binding silently stops happening and
/// every alert loses its way out. The old implementation then guessed from a set of *English*
/// titles, which fails for exactly the same reason and in the same silence — an English screenshot
/// looks perfect.
///
/// So the choice must not be readable from a title, and these tests are written to fail if it ever
/// becomes so again: the Russian cases carry no English word anywhere.
///
/// **Return is asserted beside Escape throughout**, because the 2026-08-20 report was of *both* keys
/// beeping and they failed on different alerts for different reasons: Escape was dead on the three
/// single-button progress sheets (the helper was a no-op once an accessory was present), and Return
/// was dead wherever the safe choice occupies the default slot (AppKit withholds `defaultButtonCell`
/// entirely). Asserting one key alone passes against a build where the other is unanswerable, which
/// is exactly how both shipped — so ``answerableKeys`` checks the pair on every shape.
@Suite("Escape to dismiss")
@MainActor
struct EscapeToDismissTests {
    private static let escape = "\u{1b}"

    private func alert(_ titles: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "probe"
        for title in titles { alert.addButton(withTitle: title) }
        return alert
    }

    @Test("the last button answers Escape by default — where a Cancel belongs")
    func defaultsToLastButton() {
        let alert = alert(["Replace", "Cancel"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.last?.keyEquivalent == Self.escape)
        #expect(alert.buttons.first?.keyEquivalent != Self.escape)
    }

    /// The regression the localization audit turned up: with no English title to match, the old
    /// code fell through to the last button in every translated build.
    @Test("a translated Cancel still answers Escape")
    func translatedCancelStillBinds() {
        let alert = alert(["Заменить", "Отмена"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.last?.keyEquivalent == Self.escape)
    }

    @Test("a named safe response wins over the last-button default")
    func namedResponseWins() {
        let alert = alert(["OK", "Open System Settings"])
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        // The safe choice sits in the default slot, so it keeps Return and Escape rides the catcher
        // — the alternative, moving Escape onto it, is what left this alert with no Return at all.
        #expect(escapeTarget(of: alert) === alert.buttons.first)
        #expect(alert.buttons.last?.keyEquivalent != Self.escape)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// AppKit gives an English "Cancel" Escape as the alert is built. When the caller names a
    /// different button, that stale binding has to be cleared — two buttons answering Escape is
    /// undefined, and the wrong one may win.
    @Test("AppKit's own English binding is moved, not left alongside ours")
    func stalePlatformBindingIsCleared() {
        let alert = alert(["Cancel", "Trust New Key & Connect"])
        // Precondition: this is AppKit's doing, not ours — if it ever stops, the test below is moot.
        #expect(alert.buttons.first?.keyEquivalent == Self.escape)
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)
        let bound = alert.buttons.filter { $0.keyEquivalent == Self.escape }
        #expect(bound.count <= 1)
        #expect(escapeTarget(of: alert) === alert.buttons.last)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// A translated Cancel added *first* to make it rightmost — the host-key alert's shape. AppKit
    /// gives it Return rather than Escape here, so without naming it the alert has no way out.
    @Test("a translated Cancel added first is reachable when it is named")
    func translatedCancelAddedFirst() {
        let alert = alert(["Отмена", "Доверять новому ключу"])
        #expect(alert.buttons.first?.keyEquivalent != Self.escape)
        alert.enableEscapeToCancel(safe: .alertFirstButtonReturn)
        #expect(escapeTarget(of: alert) === alert.buttons.first)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// One button can't carry Return *and* Escape, so a lone-button alert keeps its default and
    /// answers Escape through a zero-size catcher that clicks it.
    @Test("a lone button keeps Return and gets a catcher instead")
    func loneButtonGetsCatcher() {
        let alert = alert(["OK"])
        alert.enableEscapeToCancel()
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(catcher(in: alert) != nil)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// The catcher must not take the `accessoryView` slot. It used to, and that is the whole of the
    /// progress-sheet bug: the three progress sheets each set a real accessory, so the helper either
    /// declined (accessory already there) or had its catcher thrown away by the caller's assignment.
    /// Measured on a live sheet: `performKeyEquivalent(⎋) == false` and the sheet did not dismiss.
    @Test("an alert with a real accessory still answers Escape, in either call order")
    func accessoryDoesNotDisplaceTheCatcher() {
        for accessoryFirst in [true, false] {
            let alert = alert(["Stop"])
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = true
            bar.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
            if accessoryFirst {
                alert.accessoryView = bar
                alert.enableEscapeToCancel()
            } else {
                alert.enableEscapeToCancel()
                alert.accessoryView = bar
            }
            #expect(alert.accessoryView === bar)
            #expect(catcher(in: alert) != nil)
            #expect(answerableKeys(of: alert) == .both)
        }
    }

    /// The three plain "something went wrong" alerts add no button at all and let AppKit supply the
    /// OK. Probed: `buttons` already reports that synthesized button before anything lays out, so
    /// the lone-button branch above covers them unchanged — worth pinning, because if `buttons`
    /// ever came back empty the helper would do *nothing* and say so to no one.
    @Test("an alert that adds no button still gets a catcher for AppKit's synthesized OK")
    func synthesizedButtonGetsAccessory() {
        let alert = alert([])
        #expect(alert.buttons.count == 1) // precondition: AppKit's doing, not ours
        alert.enableEscapeToCancel()
        #expect(catcher(in: alert) != nil)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// Escape is the only thing the helper may touch. A sheet whose Return commits real work (the
    /// New Folder name field) must keep committing it in every language.
    @Test("the confirming button's Return survives")
    func returnIsUntouched() {
        let alert = alert(["Создать", "Отмена"])
        #expect(alert.buttons.first?.keyEquivalent == "\r") // AppKit's, before we touch anything
        alert.enableEscapeToCancel()
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == Self.escape)
    }

    /// An out-of-range response must not crash or bind nothing — it falls back to the default.
    @Test("a response naming a button that isn't there falls back to the last one")
    func outOfRangeResponseFallsBack() {
        let threeButtons = alert(["Retry", "Skip", "Abort"])
        threeButtons.enableEscapeToCancel(safe: .alertThirdButtonReturn)
        #expect(threeButtons.buttons.last?.keyEquivalent == Self.escape)
        // Same response, but there is no third button to hand it to.
        let twoButtons = alert(["Да", "Нет"])
        twoButtons.enableEscapeToCancel(safe: .alertThirdButtonReturn)
        #expect(twoButtons.buttons.last?.keyEquivalent == Self.escape)
    }

    /// The invariant the report came down to: **every alert the app builds answers both keys.**
    ///
    /// One case per shape that exists in `Dirnex/`, English and translated. Two of these were dead
    /// in the shipped build — the progress sheet had no Escape, the trust prompt no Return — and
    /// each was invisible to a test that asserted only the other key.
    @Test(
        "every alert shape answers Escape and Return",
        arguments: [
            (["Delete", "Cancel"], nil as NSApplication.ModalResponse?, false),
            (["Download", "Cancel"], .alertSecondButtonReturn, false),
            (["Удалить", "Отмена"], nil, false),
            (["Cancel", "Trust New Key & Connect"], .alertFirstButtonReturn, false),
            (["Отмена", "Доверять"], .alertFirstButtonReturn, false),
            (["OK", "Open System Settings"], .alertFirstButtonReturn, false),
            (["Retry", "Skip", "Abort"], nil, false),
            (["OK"], nil, false),
            (["Stop"], nil, true), // the progress sheets: one button + a real accessory
            (["Остановить"], nil, true)
        ]
    )
    func everyShapeAnswersBothKeys(
        titles: [String],
        safe: NSApplication.ModalResponse?,
        withAccessory: Bool
    ) {
        let alert = alert(titles)
        if withAccessory {
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
            alert.accessoryView = bar
        }
        alert.enableEscapeToCancel(safe: safe)
        #expect(answerableKeys(of: alert) == .both)
    }

    /// Escape must never be answered twice by two things *racing*. It cannot be: the catcher is the
    /// last subview of the content view and `NSView.performKeyEquivalent` stops at the first `true`,
    /// so a button carrying ⎋ matches before the catcher is ever reached. What this pins is the
    /// ordering that guarantee rests on, plus the one-catcher invariant.
    @Test("Escape has a single, ordered answer")
    func escapeHasOneAnswer() {
        for titles in [["Delete", "Cancel"], ["OK"]] {
            let alert = alert(titles)
            alert.enableEscapeToCancel()
            let subviews = alert.window.contentView?.subviews ?? []
            #expect(subviews.last is AlertKeyCatcher)
            #expect(subviews.filter { $0 is AlertKeyCatcher }.count == 1)
        }
        // And the ordinary confirmation still binds ⎋ on the button, which matches first.
        let confirmation = alert(["Delete", "Cancel"])
        confirmation.enableEscapeToCancel()
        #expect(confirmation.buttons.last?.keyEquivalent == Self.escape)
    }

    /// Calling twice must not leave two catchers aimed at different buttons.
    @Test("a second call replaces the first catcher rather than stacking one")
    func catcherIsIdempotent() {
        let alert = alert(["OK"])
        alert.enableEscapeToCancel()
        alert.enableEscapeToCancel()
        let catchers = alert.window.contentView?.subviews.filter { $0 is AlertKeyCatcher } ?? []
        #expect(catchers.count == 1)
    }

    // MARK: - Reading the bindings back

    /// Which of the two keys this alert can answer. Named rather than a tuple of `Bool`s so a
    /// failure message says *which* key is dead.
    private struct AnswerableKeys: Equatable, CustomStringConvertible {
        var escape: Bool
        var `return`: Bool
        static let both = AnswerableKeys(escape: true, return: true)
        var description: String {
            "escape: \(escape ? "answered" : "DEAD"), return: \(`return` ? "answered" : "DEAD")"
        }
    }

    /// Escape is answered by a button carrying it or by the catcher; Return by whichever button
    /// carries `\r`, which is also what makes AppKit draw a default button at all.
    private func answerableKeys(of alert: NSAlert) -> AnswerableKeys {
        AnswerableKeys(
            escape: escapeTarget(of: alert) != nil,
            return: alert.buttons.contains { $0.keyEquivalent == "\r" }
        )
    }

    /// The button *bare* Escape reaches, whichever mechanism carries it.
    private func escapeTarget(of alert: NSAlert) -> NSButton? {
        if let bound = alert.buttons.first(where: { $0.keyEquivalent == Self.escape }) { return bound }
        // Otherwise the catcher answers it — ask the catcher itself which button it would click,
        // rather than restating its rule here.
        let escape = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: Self.escape, charactersIgnoringModifiers: Self.escape,
            isARepeat: false, keyCode: 53
        )
        return escape.flatMap { catcher(in: alert)?.button(for: $0) }
    }

    private func catcher(in alert: NSAlert) -> AlertKeyCatcher? {
        alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
    }
}
