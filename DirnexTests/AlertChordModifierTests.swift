import AppKit
import Testing

@testable import Dirnex

/// The keys a dialog raised by a **modifier chord** has to answer.
///
/// Reported 2026-08-21 against the remote-download confirmation: ⎋ took two presses and ⏎ never
/// worked at all. Nothing was wrong with the binding, which is why it took a probe to find —
/// `Cancel[⎋]` and `Download[⏎]` were correctly bound, the sheet was key, and the Quick View key
/// monitor bowed out exactly as it should. AppKit matches a key equivalent on the character **and**
/// the exact modifier mask, and ⌃Q raises that dialog **53 ms** after the chord, so the key arrives
/// with Control still down, is refused, falls through to `keyDown:`, and beeps. The app's own log
/// has it as `modifiers = [ctrl]` against `Cancel:chars=true,mods=false`.
///
/// Asserted as **which button the key reaches**, on a real alert built by the real helper, with no
/// sheet presented. Presenting was tried and cannot be: tearing an `NSAlert` sheet down inside the
/// test host segfaults in AppKit's own completion block (`objc_release` in
/// `__destroy_helper_block_…`), which kills the runner and lists every suite in flight as failing —
/// naming features that work. `.serialized` did not help; the crash is in the teardown itself.
/// So the click landing is covered by a live run against real sheets (13 cases, docs/NOTES.md) and
/// the suite covers the rule that decides it.
@Suite("Alert keys after a chord")
@MainActor
struct AlertChordModifierTests {
    /// A key press as data. `NSEvent` is not `Sendable`, so a parameterised case cannot carry one —
    /// it is built inside the test body from these.
    struct Press: Sendable, CustomStringConvertible {
        let name: String
        let keyCode: UInt16
        let characters: String
        let modifiers: UInt

        static func escape(_ modifiers: NSEvent.ModifierFlags) -> Press {
            Press(name: "⎋", keyCode: 53, characters: "\u{1b}", modifiers: modifiers.rawValue)
        }

        static func enter(_ modifiers: NSEvent.ModifierFlags) -> Press {
            Press(name: "⏎", keyCode: 36, characters: "\r", modifiers: modifiers.rawValue)
        }

        static func keypadEnter(_ modifiers: NSEvent.ModifierFlags) -> Press {
            Press(name: "keypad ⏎", keyCode: 76, characters: "\u{3}", modifiers: modifiers.rawValue)
        }

        var description: String { "\(name) + \(NSEvent.ModifierFlags(rawValue: modifiers))" }

        var event: NSEvent {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )!
        }
    }

    /// Which of an alert's buttons a key is expected to reach, by role rather than by title — a
    /// title match would pass in English and fail in thirteen languages.
    enum Expected: Sendable {
        case safe
        case confirming
        case nothing
    }

    /// One case: a key pressed against an alert built while `held` was down, and the button that
    /// must answer. A named type rather than a tuple, because a heterogeneous tuple array cannot
    /// infer `NSEvent.ModifierFlags` from a bare `.control`.
    struct Case: Sendable, CustomStringConvertible {
        let press: Press
        let held: NSEvent.ModifierFlags
        let expected: Expected

        var description: String { "\(press), alert raised holding \(held) → \(expected)" }
    }

    /// The reported bug, on both keys and both chords the app raises confirmations from.
    @Test(
        "a key still carrying the chord that raised the alert answers it",
        arguments: [
            // ⌃Q → the remote-download confirmation.
            Case(press: .escape([.control]), held: .control, expected: .safe),
            Case(press: .enter([.control]), held: .control, expected: .confirming),
            Case(press: .keypadEnter([.control]), held: .control, expected: .confirming),
            // ⇧F8 → the delete confirmation. Same shape, different chord.
            Case(press: .escape([.shift]), held: .shift, expected: .safe),
            Case(press: .enter([.shift]), held: .shift, expected: .confirming),
            // Both halves of a two-modifier chord, and either half on its own, are stale.
            Case(press: .escape([.control, .shift]), held: [.control, .shift], expected: .safe),
            Case(press: .escape([.control]), held: [.control, .shift], expected: .safe)
        ]
    )
    func staleChordModifiersAreForgiven(_ testCase: Case) {
        #expect(reached(testCase) == testCase.expected)
    }

    /// The control that says the **capture** is what does it, and the one that fails the moment the
    /// fix is reverted: the identical event against an alert nothing was held for stays refused.
    /// That is every dialog raised by a click, which must go on behaving exactly as it did.
    @Test(
        "the same key is refused where no chord was held",
        arguments: [Press.escape([.control]), Press.enter([.control]), Press.escape([.option])]
    )
    func modifiersAreRefusedWithoutAChord(press: Press) {
        #expect(reached(Case(press: press, held: [], expected: .nothing)) == .nothing)
    }

    /// The narrowness that makes forgiving ⏎ affordable at all. Only the modifiers of the chord that
    /// raised *this* alert are stale; a different one is somebody pressing a deliberate combination,
    /// and ⏎ is the committing direction — being wrong there costs a file.
    @Test(
        "a modifier the chord did not carry stays refused",
        arguments: [
            Case(press: .enter([.command]), held: .control, expected: .nothing),
            Case(press: .escape([.command]), held: .control, expected: .nothing),
            // A superset is not stale either: ⌃ was held, ⌃⌘ was not.
            Case(press: .enter([.control, .command]), held: .control, expected: .nothing)
        ]
    )
    func aDifferentModifierIsNotStale(_ testCase: Case) {
        #expect(reached(testCase) == .nothing)
    }

    /// Caps Lock is not a chord modifier, and AppKit ignores it for key equivalents — so subtracting
    /// it leaves a bare key, which is answered even on an alert that captured no chord at all. The
    /// alternative would be a dialog that stops answering Escape because Caps Lock is on.
    @Test("Caps Lock does not stop a key being answered")
    func capsLockIsIgnored() {
        let alert = confirmation(held: [])
        #expect(
            catcher(in: alert)?.button(for: Press.escape([.capsLock]).event) === alert.buttons.last
        )
        #expect(
            catcher(in: alert)?.button(for: Press.enter([.capsLock]).event) === alert.buttons.first
        )
        // And Caps Lock alone must not make a *real* chord modifier look stale.
        #expect(catcher(in: alert)?.button(for: Press.escape([.capsLock, .command]).event) == nil)
    }

    /// The bare keys are answered here too, and that is the fix for the *second* defect: measured in
    /// the running app, the catcher is walked even on presses that work, so reaching it means no
    /// button claimed the key — and the responder-chain fallback that normally answers it
    /// intermittently does not run, leaving a live dialog that beeps. Claiming it here makes the
    /// walk itself decide.
    ///
    /// The buttons keep their own bindings: those match *first* in the walk, so this changes which
    /// mechanism answers only when AppKit's own matching has already declined.
    @Test("the bare keys are answered, chord or no chord")
    func bareKeysAreAnswered() {
        for held: NSEvent.ModifierFlags in [[], .control] {
            let alert = confirmation(held: held)
            let catcher = catcher(in: alert)
            #expect(catcher?.button(for: Press.escape([]).event) === alert.buttons.last)
            #expect(catcher?.button(for: Press.enter([]).event) === alert.buttons.first)
            // Untouched, and still first in the walk.
            #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
            #expect(alert.buttons.first?.keyEquivalent == "\r")
        }
    }

    /// The catcher is the *last* subview of the alert's content view, which is the whole reason
    /// claiming the bare keys cannot double-answer: `NSView.performKeyEquivalent` stops at the first
    /// responder that returns `true`, so being reached means nothing before it matched.
    @Test("the catcher is walked last")
    func catcherIsWalkedLast() throws {
        let alert = confirmation(held: [])
        let subviews = try #require(alert.window.contentView?.subviews)
        #expect(subviews.last is AlertKeyCatcher)
        #expect(subviews.filter { $0 is AlertKeyCatcher }.count == 1)
    }

    /// The lone-button progress sheet, where bare ⎋ already rode the catcher — it must answer the
    /// chord-modified key too, and its single button is both the safe and the default choice.
    @Test("a lone-button sheet answers Escape bare and after a chord")
    func loneButtonAnswersBothEscapes() {
        let alert = NSAlert()
        alert.messageText = "probe"
        alert.addButton(withTitle: "Stop")
        alert.enableEscapeToCancel(heldModifiers: [.control])
        let catcher = catcher(in: alert)
        #expect(catcher?.button(for: Press.escape([]).event) === alert.buttons.first)
        #expect(catcher?.button(for: Press.escape([.control]).event) === alert.buttons.first)
    }

    /// A key that is neither ⎋ nor ⏎ is nobody's business here, however stale its modifiers.
    @Test("an ordinary key is not claimed")
    func otherKeysAreUntouched() {
        let alert = confirmation(held: [.control])
        let press = Press(
            name: "a",
            keyCode: 0,
            characters: "a",
            modifiers: NSEvent.ModifierFlags.control.rawValue
        )
        #expect(catcher(in: alert)?.button(for: press.event) == nil)
    }

    // MARK: - Plumbing

    /// The remote-download confirmation's exact shape: `Download` then `Cancel`, safe = the second.
    private func confirmation(held: NSEvent.ModifierFlags) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "probe"
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn, heldModifiers: held)
        return alert
    }

    /// Which button the press reaches, named by role.
    private func reached(_ testCase: Case) -> Expected {
        let alert = confirmation(held: testCase.held)
        guard let button = catcher(in: alert)?.button(for: testCase.press.event) else {
            return .nothing
        }
        if button === alert.buttons.last { return .safe }
        if button === alert.buttons.first { return .confirming }
        return .nothing
    }

    private func catcher(in alert: NSAlert) -> AlertKeyCatcher? {
        alert.window.contentView?.subviews.compactMap { $0 as? AlertKeyCatcher }.first
    }
}
