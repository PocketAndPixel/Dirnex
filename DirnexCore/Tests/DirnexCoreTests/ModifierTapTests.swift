import Foundation
import Testing

@testable import DirnexCore

@Suite("ModifierTap")
struct ModifierTapTests {
    /// A limit a `Double` holds exactly, so the boundary case measures the rule rather than
    /// rounding: 10.4 − 10.0 is a hair over 0.4.
    private func optionTap() -> ModifierTap {
        ModifierTap(modifier: .option, maximumDuration: 0.25)
    }

    /// Whether the change to `now` ends a tap. Outside `#expect`, whose expansion cannot call a
    /// mutating method.
    private func ends(
        _ tap: inout ModifierTap,
        to now: CommandShortcut.Modifiers,
        at time: TimeInterval
    ) -> Bool {
        tap.modifiersChanged(to: now, at: time)
    }

    @Test("a quick press and release of ⌥ alone is a tap")
    func quickPressIsATap() {
        var tap = optionTap()
        #expect(!ends(&tap, to: .option, at: 10.0))
        #expect(ends(&tap, to: [], at: 10.15))
    }

    @Test("a press as long as the limit still counts, and one past it does not")
    func limit() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        #expect(ends(&tap, to: [], at: 10.25))

        _ = tap.modifiersChanged(to: .option, at: 20.0)
        #expect(!ends(&tap, to: [], at: 20.26))
    }

    @Test("a key, a click or a scroll between the press and the release spoils the tap")
    func interruptionSpoilsTheTap() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        tap.interrupt()
        #expect(!ends(&tap, to: [], at: 10.1))
    }

    @Test("a second modifier joining spoils the tap, whichever goes down first")
    func secondModifierSpoilsTheTap() {
        var tap = optionTap()
        // ⌥, then ⇧ with it, then both up in either order.
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        _ = tap.modifiersChanged(to: [.option, .shift], at: 10.05)
        #expect(!ends(&tap, to: .option, at: 10.1))
        #expect(!ends(&tap, to: [], at: 10.15))

        // ⇧ first, then ⌥; ⇧ let go leaves ⌥ held alone, which is not a fresh press.
        _ = tap.modifiersChanged(to: .shift, at: 20.0)
        _ = tap.modifiersChanged(to: [.shift, .option], at: 20.05)
        #expect(!ends(&tap, to: .option, at: 20.1))
        #expect(!ends(&tap, to: [], at: 20.15))
    }

    /// Both ⌥ keys report the same modifier, so the second press reads as ⌥ again while ⌥ is held.
    @Test("pressing both ⌥ keys is not a tap")
    func bothOptionKeys() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        _ = tap.modifiersChanged(to: .option, at: 10.05)
        #expect(!ends(&tap, to: .option, at: 10.1))
        #expect(!ends(&tap, to: [], at: 10.15))
    }

    @Test("a release whose press was never seen is not a tap")
    func releaseWithoutPress() {
        var tap = optionTap()
        #expect(!ends(&tap, to: [], at: 10.0))
    }

    @Test("a tap of another modifier is not a tap of ⌥")
    func otherModifier() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .command, at: 10.0)
        #expect(!ends(&tap, to: [], at: 10.1))
    }

    @Test("after a spoiled press, the next clean one is a tap again")
    func recoversAfterASpoiledPress() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        tap.interrupt()
        _ = tap.modifiersChanged(to: [], at: 10.1)

        _ = tap.modifiersChanged(to: .option, at: 11.0)
        #expect(ends(&tap, to: [], at: 11.1))
    }

    @Test("starting again while ⌥ is held does not make its release a tap")
    func resetWhileHeld() {
        var tap = optionTap()
        tap.reset(holding: .option)
        #expect(!ends(&tap, to: [], at: 10.1))
        _ = tap.modifiersChanged(to: .option, at: 11.0)
        #expect(ends(&tap, to: [], at: 11.1))
    }

    /// The release of a press that happened in another app is missed, so the recognizer still
    /// thinks ⌥ is held. Starting again from the keyboard lets the next press count.
    @Test("starting again from nothing held lets a stale ⌥ go")
    func resetFromNothing() {
        var tap = optionTap()
        _ = tap.modifiersChanged(to: .option, at: 10.0)
        tap.reset(holding: [])
        _ = tap.modifiersChanged(to: .option, at: 11.0)
        #expect(ends(&tap, to: [], at: 11.1))
    }
}
