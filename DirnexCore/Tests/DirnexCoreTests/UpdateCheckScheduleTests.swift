import Foundation
import Testing

@testable import DirnexCore

@Suite("UpdateCheckSchedule")
struct UpdateCheckScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let schedule = UpdateCheckSchedule()

    @Test("the shipping interval is eight hours")
    func defaultIntervalIsEightHours() {
        #expect(UpdateCheckSchedule.defaultInterval == 28800)
        #expect(schedule.interval == 28800)
    }

    @Test("never probed — a fresh install is due immediately")
    func neverProbedIsDue() {
        #expect(schedule.isDue(lastCheck: nil, now: now))
        #expect(schedule.delayUntilNextCheck(lastCheck: nil, now: now) == 0)
    }

    @Test("a probe an instant ago is not due, and waits out the remainder")
    func recentProbeIsNotDue() {
        let lastCheck = now.addingTimeInterval(-60)
        #expect(!schedule.isDue(lastCheck: lastCheck, now: now))
        #expect(schedule.delayUntilNextCheck(lastCheck: lastCheck, now: now) == 28740)
    }

    @Test("exactly one interval elapsed counts as due")
    func exactIntervalIsDue() {
        let lastCheck = now.addingTimeInterval(-28800)
        #expect(schedule.isDue(lastCheck: lastCheck, now: now))
        #expect(schedule.delayUntilNextCheck(lastCheck: lastCheck, now: now) == 0)
    }

    @Test("a long sleep leaves the probe due rather than owing a negative delay")
    func overdueProbeIsDue() {
        // The one-shot timer does not fire while the machine is asleep, so the app comes back with
        // days of elapsed time. The delay must clamp at zero, not go negative.
        let lastCheck = now.addingTimeInterval(-3 * 24 * 60 * 60)
        #expect(schedule.isDue(lastCheck: lastCheck, now: now))
        #expect(schedule.delayUntilNextCheck(lastCheck: lastCheck, now: now) == 0)
    }

    @Test("a last-check in the future is treated as due, not as a lock")
    func futureLastCheckIsDue() {
        // Clock skew (or a defaults value carried over from a machine set ahead) would otherwise
        // hold the schedule shut for the length of the skew, and silently: no probe, no indicator,
        // no error. Being due is the safe direction.
        let lastCheck = now.addingTimeInterval(60 * 60)
        #expect(schedule.isDue(lastCheck: lastCheck, now: now))
        #expect(schedule.delayUntilNextCheck(lastCheck: lastCheck, now: now) == 0)
    }

    @Test("a nonsense interval is floored at a minute so the timer cannot busy-loop")
    func intervalIsFloored() {
        #expect(UpdateCheckSchedule(interval: 0).interval == 60)
        #expect(UpdateCheckSchedule(interval: -5).interval == 60)
        #expect(UpdateCheckSchedule(interval: 120).interval == 120)
    }

    @Test("the delay never exceeds one interval")
    func delayIsBoundedByInterval() {
        let short = UpdateCheckSchedule(interval: 120)
        for offset in stride(from: -300.0, through: 300.0, by: 15) {
            let delay = short.delayUntilNextCheck(
                lastCheck: now.addingTimeInterval(offset),
                now: now
            )
            #expect(delay >= 0)
            #expect(delay <= short.interval)
        }
    }
}
