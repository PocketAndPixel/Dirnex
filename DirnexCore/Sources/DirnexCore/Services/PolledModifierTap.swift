import Foundation

/// ``ModifierTap`` read by sampling the keyboard rather than from events, for where no event reaches
/// the app. An open menu runs its own event loop, so a second tap of ⌥ that should close the context
/// menu never reaches the app's monitors (measured 2026-10-25).
///
/// Each sample is the modifiers held and a running count of key presses and clicks. A count that
/// moved spoils the press under way, as a key or a click does outside the menu, and it holds back a
/// tap that ends in the same sample, so the order the two were sampled in does not matter.
public struct PolledModifierTap: Sendable, Equatable {
    private var tap: ModifierTap
    private var held: CommandShortcut.Modifiers
    private var inputCount: Int

    /// Start from what the keyboard holds and the count of presses and clicks so far. A modifier
    /// already held when sampling starts is not the start of a tap.
    public init(
        modifier: CommandShortcut.Modifiers,
        maximumDuration: TimeInterval,
        holding: CommandShortcut.Modifiers,
        inputCount: Int
    ) {
        tap = ModifierTap(modifier: modifier, maximumDuration: maximumDuration)
        tap.reset(holding: holding)
        held = holding
        self.inputCount = inputCount
    }

    /// One sample: the modifiers `now` held and the count of presses and clicks so far, at `time`.
    /// `true` when this sample ends a tap.
    public mutating func sample(
        holding now: CommandShortcut.Modifiers,
        inputCount count: Int,
        at time: TimeInterval
    ) -> Bool {
        var ended = false
        if now != held {
            held = now
            ended = tap.modifiersChanged(to: now, at: time)
        }
        guard count == inputCount else {
            inputCount = count
            tap.interrupt()
            return false
        }
        return ended
    }
}
