import Foundation

/// What the reminder remembers between launches. The app keeps it in preferences.
public struct LicenseReminderRecord: Sendable, Equatable, Codable {
    /// When the quiet period began: the first launch of a build with the licensing switch on.
    public var graceStart: Date?
    /// When the reminder last appeared.
    public var lastShown: Date?

    public init(graceStart: Date? = nil, lastShown: Date? = nil) {
        self.graceStart = graceStart
        self.lastShown = lastShown
    }
}

/// Which reminder a build shows, when it shows one (PLAN.md §M29 "What it is").
public enum LicenseReminderVariant: Sendable, Equatable {
    /// No key: **Buy a License**.
    case buy
    /// A key whose period ended before this build came out: **Renew**, naming the key's last day.
    case renew(until: LicenseDay)
}

public extension LicenseStatus {
    /// The reminder this status calls for, or `nil` when a key covers this build: then there's no
    /// reminder and no titlebar label at all.
    var reminderVariant: LicenseReminderVariant? {
        switch self {
        case .unlicensed: .buy
        case .licensed: nil
        case let .lapsed(key): .renew(until: key.until)
        }
    }
}

/// When the license reminder appears (PLAN.md §M29 "Thirty quiet days", "When it appears").
///
/// - Nothing for the first ``defaultGracePeriod``, counted from the first launch of a build with
///   the switch on, not from install. So nobody who used an earlier, dormant build meets the
///   reminder on the day it arrives.
/// - After that, while no key covers this build: at every launch, and once a day at the first
///   activation from ``defaultDailyHour`` (13:00) in the Mac's time zone. Macs sleep rather than
///   quit, so launch alone would almost never fire.
/// - The daily one waits for the afternoon (Oleg, 2026-10-01). With the day starting at midnight,
///   a late session met it again just after 00:00, and in the morning it lands on the first minutes
///   of work, when someone opens Dirnex to get something done. So someone who uses Dirnex only in
///   the mornings sees it only when Dirnex starts, which is acceptable for a request, not a lock.
///
/// Every rule is a named constant or one line here, so changing the cadence after launch feedback
/// is a small, tested change. PLAN.md §6 names the risk: a sheet at every launch is the most hostile
/// thing Dirnex does.
public struct LicenseReminderPolicy: Sendable {
    public enum Trigger: Sendable {
        case launch
        /// The app became active again, typically after the Mac woke.
        case activation
    }

    public static let defaultGracePeriod: TimeInterval = 30 * 24 * 60 * 60

    /// The hour, in the Mac's time zone, from which the daily reminder may appear: 13:00.
    public static let defaultDailyHour = 13

    public let gracePeriod: TimeInterval
    public let dailyHour: Int
    /// The Mac's calendar and time zone, which decide where one day ends and what hour it is.
    public let calendar: Calendar

    public init(
        gracePeriod: TimeInterval = Self.defaultGracePeriod,
        dailyHour: Int = Self.defaultDailyHour,
        calendar: Calendar = .current
    ) {
        self.gracePeriod = gracePeriod
        self.dailyHour = dailyHour
        self.calendar = calendar
    }

    /// The record with its quiet period started. Call it at every launch of a build with the switch
    /// on, and save the result.
    ///
    /// A start in the future means the clock was ahead when it was written, or has since been set
    /// back. It's pulled back to now, so the quiet period ends 30 days from now instead of 30 days
    /// after a date that may be years away. Setting the clock back therefore buys at most one more
    /// quiet period, and the reminder is a request, not a lock.
    public func armed(_ record: LicenseReminderRecord, now: Date) -> LicenseReminderRecord {
        var record = record
        if let start = record.graceStart, start <= now { return record }
        record.graceStart = now
        return record
    }

    /// Whether the reminder is due at all: the quiet period is over and no key covers this build.
    /// The titlebar's "Unlicensed" label shows exactly while this is true.
    public func isDue(_ status: LicenseStatus, record: LicenseReminderRecord, now: Date) -> Bool {
        guard !status.isCovered, let start = record.graceStart else { return false }
        return now.timeIntervalSince(start) >= gracePeriod
    }

    /// Whether to show the reminder now.
    ///
    /// On activation it shows from ``dailyHour`` on, when it last appeared on a *different* calendar
    /// day. So a reminder at a morning launch counts for that day, and there's no second one after
    /// 13:00. "Different", not "earlier": after the clock moves backwards, "earlier" could stay false
    /// for as long as the clock was wrong; "different" puts it back on its daily rhythm at once.
    public func shouldShow(
        _ trigger: Trigger,
        status: LicenseStatus,
        record: LicenseReminderRecord,
        now: Date
    ) -> Bool {
        guard isDue(status, record: record, now: now) else { return false }
        switch trigger {
        case .launch:
            return true
        case .activation:
            guard calendar.component(.hour, from: now) >= dailyHour else { return false }
            guard let lastShown = record.lastShown else { return true }
            return !calendar.isDate(lastShown, inSameDayAs: now)
        }
    }

    /// The record after the reminder actually appeared. The app calls it when the sheet is
    /// presented, not when ``shouldShow(_:status:record:now:)`` said yes, since the sheet may wait
    /// behind the first-run tour.
    public func recordingShown(_ record: LicenseReminderRecord, now: Date) -> LicenseReminderRecord {
        var record = record
        record.lastShown = now
        return record
    }
}
