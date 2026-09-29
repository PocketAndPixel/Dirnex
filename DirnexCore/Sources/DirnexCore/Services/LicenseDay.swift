import Foundation

/// A calendar day as a license names it (PLAN.md §M29): `YYYY-MM-DD`, with no time and no zone.
///
/// A key's `issued` and `until`, and a build's release date, are all **UTC** days, and whether a key
/// covers a build is a comparison of two of them. It never goes through a `Date`, deliberately:
/// midnight UTC printed in California is the day before, and whether a paying customer sees the
/// reminder must not depend on where their Mac is.
///
/// The same care applies when a day is *shown*. ``date(in:)`` gives noon of the day in the viewer's
/// time zone, so a formatter in that zone prints the day the key names, never the one next to it.
public struct LicenseDay: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Parses `YYYY-MM-DD` strictly: ASCII digits, a day that exists, and a year from 2000 to 9999.
    /// The signer's `isLicenseDay` has the same rule, and the shared vectors pin it
    /// (`impossible-date`).
    ///
    /// The floor at 2000 isn't arbitrary: JavaScript's `Date.UTC` maps the years 0–99 to 1900–1999,
    /// so below it the signer and the app would disagree about leap days.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              year >= 2000, (1...12).contains(month),
              (1...Self.daysIn(month: month, year: year)).contains(day)
        else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `timeZone`. A build's release date and an update's `pubDate` are
    /// read in UTC, the zone the signer's dates are in.
    public init(_ date: Date, in timeZone: TimeZone = .gmt) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Noon of this day in `timeZone`, for display. Format it with a formatter in the same zone (the
    /// default for `Date.FormatStyle`) and the printed day is this one. Noon rather than midnight,
    /// because a daylight-saving change can skip midnight.
    public func date(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: year, month: month, day: day, hour: 12)
        return calendar.date(from: parts) ?? .distantPast
    }

    public var description: String {
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(year, 4))-\(padded(month, 2))-\(padded(day, 2))"
    }

    public static func < (lhs: LicenseDay, rhs: LicenseDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let isLeap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
