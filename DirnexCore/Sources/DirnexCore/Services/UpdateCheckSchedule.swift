import Foundation

/// When the background update probe is allowed to run (PLAN.md §M7 "Sparkle 2 updates").
///
/// Sparkle's own scheduler is deliberately not what drives Dirnex's titlebar indicator. Its
/// automatic checks are gated behind the first-run permission prompt — answer that prompt "no"
/// once and `SUEnableAutomaticChecks` is `0` forever, so no scheduled check ever runs and
/// `AppUpdater.availability` stays `.none` no matter how many releases ship. The app instead runs
/// its own silent `checkForUpdateInformation()` probe, which shows no UI at all and only lights the
/// indicator; this type owns the "is it time yet" half of that.
///
/// A value type in `DirnexCore` rather than a timer interval buried in the app, for the same reason
/// as `UpdateAvailability`: the arithmetic is the part that can be wrong — a clock that moved
/// backwards must not wedge the schedule shut, and a delay must never come back negative or zero
/// and spin the runloop — so it is unit-tested and the app is left holding a `Timer`.
public struct UpdateCheckSchedule: Sendable, Equatable {
    /// Eight hours: three probes a day, which keeps a fresh release visible within one working
    /// session without making the app a poller. The launch probe is unconditional, so a relaunch
    /// always refreshes the indicator regardless of this interval.
    public static let defaultInterval: TimeInterval = 8 * 60 * 60

    /// The gap between probes. Floored at a minute so a nonsense value cannot turn the timer into a
    /// busy loop against the network.
    public let interval: TimeInterval

    public init(interval: TimeInterval = Self.defaultInterval) {
        self.interval = max(60, interval)
    }

    /// Whether a probe is owed. `nil` — never probed on this install — counts as owed, as does a
    /// `lastCheck` in the future: a clock that jumped forward and back (or a defaults value written
    /// by a machine in another timezone's idea of "now") would otherwise hold the schedule shut for
    /// however long the skew lasted, and the failure would be silent in the quiet direction.
    public func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= interval
    }

    /// How long to wait before the next probe. Always in `0...interval`: zero when one is already
    /// owed, and never more than a full interval even if `lastCheck` sits in the future.
    public func delayUntilNextCheck(lastCheck: Date?, now: Date) -> TimeInterval {
        guard !isDue(lastCheck: lastCheck, now: now), let lastCheck else { return 0 }
        return min(interval, interval - now.timeIntervalSince(lastCheck))
    }
}
