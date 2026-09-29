import Foundation
import Testing

@testable import DirnexCore

@Suite("LicenseReminderPolicy")
struct LicenseReminderPolicyTests {
    private static let day: TimeInterval = 24 * 60 * 60

    /// 2027-01-10 09:00 in Kyiv (07:00 UTC).
    private let firstLaunch = Date(timeIntervalSince1970: 1_799_564_400)

    private let policy: LicenseReminderPolicy = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        return LicenseReminderPolicy(calendar: calendar)
    }()

    private let covering = LicenseStatus.licensed(LicenseKey(
        text: "dnx1.test",
        id: "TESTID",
        licensee: "Jane",
        issued: LicenseDay(year: 2026, month: 9, day: 29),
        until: LicenseDay(year: 2027, month: 9, day: 29)
    ))

    private func armed(at start: Date) -> LicenseReminderRecord {
        policy.armed(LicenseReminderRecord(), now: start)
    }

    @Test("the quiet period is thirty days")
    func gracePeriodIsThirtyDays() {
        #expect(LicenseReminderPolicy.defaultGracePeriod == 30 * Self.day)
    }

    @Test("the first launch starts the quiet period, and later launches keep it")
    func arming() {
        let record = armed(at: firstLaunch)
        #expect(record.graceStart == firstLaunch)
        let later = policy.armed(record, now: firstLaunch.addingTimeInterval(5 * Self.day))
        #expect(later.graceStart == firstLaunch)
    }

    @Test("nothing during the thirty days, at launch or on a new day")
    func quietDuringGrace() {
        let record = armed(at: firstLaunch)
        for elapsed in [0, 1, 15, 29] {
            let now = firstLaunch.addingTimeInterval(TimeInterval(elapsed) * Self.day)
            #expect(!policy.shouldShow(.launch, status: .unlicensed, record: record, now: now))
            #expect(!policy.shouldShow(.activation, status: .unlicensed, record: record, now: now))
            #expect(!policy.isDue(.unlicensed, record: record, now: now))
        }
        let lastQuietSecond = firstLaunch.addingTimeInterval(30 * Self.day - 1)
        #expect(
            !policy.shouldShow(.launch, status: .unlicensed, record: record, now: lastQuietSecond)
        )
    }

    @Test("negative control: a policy that ignores the quiet period would remind on day 29")
    func ignoringGraceIsCaught() {
        let careless = LicenseReminderPolicy(gracePeriod: 0, calendar: policy.calendar)
        let record = careless.armed(LicenseReminderRecord(), now: firstLaunch)
        let dayTwentyNine = firstLaunch.addingTimeInterval(29 * Self.day)
        #expect(
            careless.shouldShow(.launch, status: .unlicensed, record: record, now: dayTwentyNine)
        )
    }

    @Test("after thirty days: at every launch, even twice on one day")
    func everyLaunch() {
        var record = armed(at: firstLaunch)
        let now = firstLaunch.addingTimeInterval(30 * Self.day)
        #expect(policy.shouldShow(.launch, status: .unlicensed, record: record, now: now))
        record = policy.recordingShown(record, now: now)
        let relaunch = now.addingTimeInterval(600)
        #expect(policy.shouldShow(.launch, status: .unlicensed, record: record, now: relaunch))
    }

    @Test("on activation: once per calendar day in the Mac's time zone")
    func oncePerDay() {
        var record = armed(at: firstLaunch)
        // Day 31, 10:00 Kyiv: shown at launch.
        let launch = firstLaunch.addingTimeInterval(31 * Self.day + 3600)
        record = policy.recordingShown(record, now: launch)

        // 23:59 the same Kyiv day: not again. (It's 21:59 UTC, so a UTC day would agree here.)
        let lateEvening = launch.addingTimeInterval(13 * 3600 + 59 * 60)
        #expect(
            !policy.shouldShow(.activation, status: .unlicensed, record: record, now: lateEvening)
        )

        // 00:30 the next Kyiv day, still 22:30 of the old day in UTC: shown.
        let pastMidnight = launch.addingTimeInterval(14 * 3600 + 30 * 60)
        #expect(
            policy.shouldShow(.activation, status: .unlicensed, record: record, now: pastMidnight)
        )
    }

    @Test("the first activation after the quiet period ends shows it, even with no launch since")
    func firstActivationAfterGrace() {
        let record = armed(at: firstLaunch)
        let now = firstLaunch.addingTimeInterval(30 * Self.day + 60)
        #expect(policy.shouldShow(.activation, status: .unlicensed, record: record, now: now))
    }

    @Test("a key that covers this build silences it; a lapsed key does not")
    func keySilences() throws {
        let record = armed(at: firstLaunch)
        let now = firstLaunch.addingTimeInterval(40 * Self.day)
        #expect(!policy.shouldShow(.launch, status: covering, record: record, now: now))
        #expect(!policy.isDue(covering, record: record, now: now))
        let key = try #require(covering.key)
        #expect(policy.shouldShow(.launch, status: .lapsed(key), record: record, now: now))
    }

    @Test("a quiet period that started in the future is pulled back to now")
    func clockSetBackBeforeGraceStart() {
        let written = LicenseReminderRecord(
            graceStart: firstLaunch.addingTimeInterval(400 * Self.day)
        )
        let record = policy.armed(written, now: firstLaunch)
        #expect(record.graceStart == firstLaunch)
        let afterGrace = firstLaunch.addingTimeInterval(30 * Self.day)
        #expect(policy.shouldShow(.launch, status: .unlicensed, record: record, now: afterGrace))
    }

    @Test("a last-shown day in the future does not hold the daily reminder shut")
    func clockSetBackAfterShowing() {
        var record = armed(at: firstLaunch)
        let shown = firstLaunch.addingTimeInterval(60 * Self.day)
        record = policy.recordingShown(record, now: shown)
        // The clock goes back three days. "A later day than last time" would stay false for three
        // days; "a different day" shows it now.
        let setBack = shown.addingTimeInterval(-3 * Self.day)
        #expect(policy.shouldShow(.activation, status: .unlicensed, record: record, now: setBack))
    }

    @Test("an unarmed record never reminds")
    func unarmed() {
        let now = firstLaunch.addingTimeInterval(100 * Self.day)
        #expect(
            !policy.shouldShow(
                .launch,
                status: .unlicensed,
                record: LicenseReminderRecord(),
                now: now
            )
        )
    }

    @Test("the record survives a round trip through preferences")
    func codable() throws {
        let record = policy.recordingShown(
            armed(at: firstLaunch),
            now: firstLaunch.addingTimeInterval(31 * Self.day)
        )
        let data = try PropertyListEncoder().encode(record)
        #expect(try PropertyListDecoder().decode(LicenseReminderRecord.self, from: data) == record)
    }
}
