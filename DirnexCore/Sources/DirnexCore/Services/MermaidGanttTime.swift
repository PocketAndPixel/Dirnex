import Foundation

/// A gantt chart's time line: wall-clock times, as milliseconds from 1970-01-01 00:00 on a calendar
/// with no time zone (PLAN.md §M39 ▸ Slice 15).
///
/// Mermaid computes a gantt in the viewer's local time through `Date` and dayjs, so a day across a
/// daylight-saving change is 23 or 25 hours wide and every date the file writes is a local
/// midnight. Here a date is its wall clock and every day is 24 hours: the bars land where the
/// file's dates say, a week is seven equal days, and no drawing depends on where the Mac is. The
/// time zone is asked only where an instant really enters, a `Z` offset, a Unix timestamp and the
/// today line (`MermaidGanttClock`), and each is turned into this wall clock once.
///
/// The calendar arithmetic is Howard Hinnant's `days_from_civil` and its inverse, proleptic
/// Gregorian, exact for every year Mermaid accepts (±10 000).
enum MermaidGanttTime {
    static let millisecondsPerDay = 86_400_000.0

    /// A wall clock's fields. `month` is 1–12 and `weekday` 0 for Sunday, as JavaScript counts it.
    struct Fields: Equatable {
        var year: Int
        var month: Int
        var day: Int
        var hour = 0
        var minute = 0
        var second = 0
        var millisecond = 0

        var weekday: Int {
            let days = MermaidGanttTime.days(year: year, month: month, day: day)
            return ((days + 4) % 7 + 7) % 7
        }
    }

    /// The time `fields` name. A day or month past its end rolls over, as JavaScript's `Date`
    /// constructor rolls it, which is what lets a strict parse see `2014-02-30` come back changed.
    static func time(_ fields: Fields) -> Double {
        let monthIndex = fields.month - 1
        let year = fields.year + floorDivide(monthIndex, 12)
        let month = floorModulo(monthIndex, 12) + 1
        let days = Self.days(year: year, month: month, day: 1) + fields.day - 1
        let seconds = Double(fields.hour) * 3600 + Double(fields.minute) * 60 + Double(fields.second)
        return Double(days) * millisecondsPerDay + seconds * 1000 + Double(fields.millisecond)
    }

    static func fields(_ time: Double) -> Fields {
        let days = Int((time / millisecondsPerDay).rounded(.down))
        var rest = Int(time - Double(days) * millisecondsPerDay)
        let date = civil(days)
        let hour = rest / 3_600_000
        rest -= hour * 3_600_000
        let minute = rest / 60000
        rest -= minute * 60000
        return Fields(
            year: date.year,
            month: date.month,
            day: date.day,
            hour: hour,
            minute: minute,
            second: rest / 1000,
            millisecond: rest % 1000
        )
    }

    static func startOfDay(_ time: Double) -> Double {
        (time / millisecondsPerDay).rounded(.down) * millisecondsPerDay
    }

    /// Days in `month` of `year`, `month` 1–12.
    static func daysInMonth(year: Int, month: Int) -> Int {
        days(year: month == 12 ? year + 1 : year, month: month == 12 ? 1 : month + 1, day: 1)
            - days(year: year, month: month, day: 1)
    }

    // MARK: - Durations

    /// A duration's unit, as Mermaid spells it after the number (`3d`, `2w`, `1M`, `30m`).
    enum Unit: String, CaseIterable {
        case millisecond = "ms"
        case second = "s"
        case minute = "m"
        case hour = "h"
        case day = "d"
        case week = "w"
        case month = "M"
        case year = "y"
    }

    /// `time` moved on by `value` `unit`s, by dayjs's `add`: days and weeks round to whole days
    /// (`1.5d` is two), months and years truncate (`1.5M` is one) and keep the day of the month
    /// unless the new month is shorter, and the rest is exact milliseconds.
    static func adding(_ value: Double, _ unit: Unit, to time: Double) -> Double {
        switch unit {
        case .day, .week:
            let days = (value * (unit == .week ? 7 : 1) + 0.5).rounded(.down)
            return time + days * millisecondsPerDay
        case .month, .year:
            var fields = fields(time)
            let day = fields.day
            if unit == .month {
                // JavaScript's `setMonth` truncates the month it is handed.
                let index = Int(Double(fields.month - 1) + value)
                fields.year += floorDivide(index, 12)
                fields.month = floorModulo(index, 12) + 1
            } else {
                fields.year = Int(Double(fields.year) + value)
            }
            fields.day = min(day, daysInMonth(year: fields.year, month: fields.month))
            return Self.time(fields)
        case .hour: return time + (value * 3_600_000).rounded(.towardZero)
        case .minute: return time + (value * 60000).rounded(.towardZero)
        case .second: return time + (value * 1000).rounded(.towardZero)
        case .millisecond: return time + value.rounded(.towardZero)
        }
    }

    // MARK: - Instants

    /// The wall clock `instant` shows in `zone`.
    static func wallClock(_ instant: Date, in zone: TimeZone) -> Double {
        (instant.timeIntervalSince1970 + Double(zone.secondsFromGMT(for: instant))) * 1000
    }

    /// The instant at which `zone`'s clocks show `time`. A wall clock that a spring change skips
    /// takes the offset from before it, which only `%Z`, `%s` and `%Q` on the axis ever ask.
    static func instant(_ time: Double, in zone: TimeZone) -> Date {
        let guess = Date(timeIntervalSince1970: time / 1000)
        let offset = zone.secondsFromGMT(for: guess)
        let first = Date(timeIntervalSince1970: time / 1000 - Double(offset))
        let settled = zone.secondsFromGMT(for: first)
        return Date(timeIntervalSince1970: time / 1000 - Double(settled))
    }

    // MARK: - The civil calendar

    static func days(year: Int, month: Int, day: Int) -> Int {
        let shifted = month <= 2 ? year - 1 : year
        let era = floorDivide(shifted, 400)
        let yearOfEra = shifted - era * 400
        let monthFromMarch = (month + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    struct CivilDate: Equatable {
        let year: Int
        let month: Int
        let day: Int
    }

    static func civil(_ days: Int) -> CivilDate {
        let shifted = days + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthFromMarch = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthFromMarch + 2) / 5 + 1
        let month = monthFromMarch < 10 ? monthFromMarch + 3 : monthFromMarch - 9
        return CivilDate(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    static func floorDivide(_ value: Int, _ divisor: Int) -> Int {
        (value - floorModulo(value, divisor)) / divisor
    }

    static func floorModulo(_ value: Int, _ divisor: Int) -> Int {
        ((value % divisor) + divisor) % divisor
    }
}
