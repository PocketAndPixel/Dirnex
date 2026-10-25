import Foundation
import Testing

@testable import DirnexCore

@Suite("PolledModifierTap")
struct PolledModifierTapTests {
    private func optionTap(holding: CommandShortcut.Modifiers = []) -> PolledModifierTap {
        PolledModifierTap(
            modifier: .option,
            maximumDuration: 0.25,
            holding: holding,
            inputCount: 100
        )
    }

    /// Whether the sample ends a tap. Outside `#expect`, whose expansion cannot call a mutating
    /// method.
    private func ends(
        _ tap: inout PolledModifierTap,
        holding now: CommandShortcut.Modifiers,
        count: Int = 100,
        at time: TimeInterval
    ) -> Bool {
        tap.sample(holding: now, inputCount: count, at: time)
    }

    @Test("⌥ seen down and then up across samples is a tap, and only the release ends it")
    func cleanTap() {
        var tap = optionTap()
        #expect(!ends(&tap, holding: [], at: 1.0))
        #expect(!ends(&tap, holding: .option, at: 1.01))
        #expect(!ends(&tap, holding: .option, at: 1.02))
        #expect(ends(&tap, holding: [], at: 1.1))
        #expect(!ends(&tap, holding: [], at: 1.11))
    }

    @Test("a press or click counted while ⌥ is down spoils the tap")
    func countBetween() {
        var tap = optionTap()
        _ = ends(&tap, holding: .option, at: 1.0)
        _ = ends(&tap, holding: .option, count: 101, at: 1.05)
        #expect(!ends(&tap, holding: [], count: 101, at: 1.1))
    }

    /// ⌥E typed fast enough that ⌥ and E land in one sample: the count moved in the very sample that
    /// starts the press.
    @Test("⌥ and a key in the same sample is not the start of a tap")
    func countWithThePress() {
        var tap = optionTap()
        _ = ends(&tap, holding: .option, count: 101, at: 1.0)
        #expect(!ends(&tap, holding: [], count: 101, at: 1.1))
    }

    @Test("a key and the release in the same sample is not a tap")
    func countWithTheRelease() {
        var tap = optionTap()
        _ = ends(&tap, holding: .option, at: 1.0)
        #expect(!ends(&tap, holding: [], count: 101, at: 1.1))
    }

    /// A right-click made with ⌥ held opens the menu with ⌥ already down.
    @Test("⌥ already held when sampling starts is not a tap when it is let go")
    func heldAtStart() {
        var tap = optionTap(holding: .option)
        #expect(!ends(&tap, holding: .option, at: 1.0))
        #expect(!ends(&tap, holding: [], at: 1.1))
        _ = ends(&tap, holding: .option, at: 2.0)
        #expect(ends(&tap, holding: [], at: 2.1))
    }

    @Test("a press held past the limit is not a tap")
    func heldTooLong() {
        var tap = optionTap()
        _ = ends(&tap, holding: .option, at: 1.0)
        #expect(!ends(&tap, holding: [], at: 1.26))
    }
}
