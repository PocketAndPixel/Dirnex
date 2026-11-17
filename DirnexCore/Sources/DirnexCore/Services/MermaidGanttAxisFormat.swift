import Foundation

/// A gantt's `axisFormat`: d3-time-format's specifiers in its `en-US` locale, which is what Mermaid
/// writes the axis's dates with (PLAN.md §M39 ▸ Slice 15).
///
/// English whatever the app's language, Oleg's call when the slice opened: a name is what GitHub
/// draws and what the author saw when choosing the format. `%-d` drops the padding, `%_d` pads with
/// a space and `%0d` with a zero, and an unknown specifier writes its letter, as d3's does.
enum MermaidGanttAxisFormat {
    static func format(_ time: Double, _ specifier: String, zone: TimeZone) -> String {
        var result = ""
        var characters = specifier[...]
        while let percent = characters.firstIndex(of: "%") {
            result += characters[..<percent]
            characters = characters[characters.index(after: percent)...]
            guard var letter = characters.first else { break }
            var pad: String?
            if letter == "-" || letter == "_" || letter == "0" {
                pad = letter == "-" ? "" : letter == "_" ? " " : "0"
                characters = characters.dropFirst()
                guard let next = characters.first else { break }
                letter = next
            }
            characters = characters.dropFirst()
            result += field(letter, time, pad: pad ?? (letter == "e" ? " " : "0"), zone: zone)
        }
        return result + characters
    }

    private static let periods = ["AM", "PM"]

    private static func field(_ letter: Character, _ time: Double, pad: String, zone: TimeZone) -> String {
        let fields = MermaidGanttTime.fields(time)
        return nameField(letter, fields)
            ?? dateField(letter, fields, pad: pad)
            ?? weekField(letter, time, fields, pad: pad)
            ?? clockField(letter, time, fields, pad: pad, zone: zone)
            ?? String(letter)
    }

    private static func nameField(_ letter: Character, _ fields: MermaidGanttTime.Fields) -> String? {
        let weekday = MermaidGanttDateFormat.weekdayNames[fields.weekday]
        let month = MermaidGanttDateFormat.monthNames[fields.month - 1]
        switch letter {
        case "a": return String(weekday.prefix(3))
        case "A": return weekday
        case "b": return String(month.prefix(3))
        case "B": return month
        case "p": return periods[fields.hour < 12 ? 0 : 1]
        default: return nil
        }
    }

    private static func dateField(
        _ letter: Character,
        _ fields: MermaidGanttTime.Fields,
        pad: String
    ) -> String? {
        switch letter {
        case "d", "e": padded(fields.day, pad, 2)
        case "j": padded(dayOfYear(fields), pad, 3)
        case "m": padded(fields.month, pad, 2)
        case "y": padded(fields.year % 100, pad, 2)
        case "Y": padded(fields.year % 10000, pad, 4)
        case "q": String((fields.month - 1) / 3 + 1)
        case "u": String(fields.weekday == 0 ? 7 : fields.weekday)
        case "w": String(fields.weekday)
        default: nil
        }
    }

    private static func weekField(
        _ letter: Character,
        _ time: Double,
        _ fields: MermaidGanttTime.Fields,
        pad: String
    ) -> String? {
        switch letter {
        case "U": padded(weekNumber(fields, firstWeekday: 0), pad, 2)
        case "W": padded(weekNumber(fields, firstWeekday: 1), pad, 2)
        case "V": padded(isoWeek(time), pad, 2)
        case "g": padded(isoWeekYear(time) % 100, pad, 2)
        case "G": padded(isoWeekYear(time) % 10000, pad, 4)
        default: nil
        }
    }

    private static func clockField(
        _ letter: Character,
        _ time: Double,
        _ fields: MermaidGanttTime.Fields,
        pad: String,
        zone: TimeZone
    ) -> String? {
        switch letter {
        case "H": padded(fields.hour, pad, 2)
        case "I": padded(fields.hour % 12 == 0 ? 12 : fields.hour % 12, pad, 2)
        case "M": padded(fields.minute, pad, 2)
        case "S": padded(fields.second, pad, 2)
        case "L": padded(fields.millisecond, pad, 3)
        case "f": padded(fields.millisecond * 1000, pad, 6)
        case "Q": String(Int(instantMilliseconds(time, zone)))
        case "s": String(Int((instantMilliseconds(time, zone) / 1000).rounded(.down)))
        case "Z": offset(time, zone)
        case "c": format(time, "%x, %X", zone: zone)
        case "x": format(time, "%-m/%-d/%Y", zone: zone)
        case "X": format(time, "%-I:%M:%S %p", zone: zone)
        default: nil
        }
    }

    /// d3's `pad`: the sign, then `fill` up to `width` digits.
    private static func padded(_ value: Int, _ fill: String, _ width: Int) -> String {
        let digits = String(abs(value))
        let padding = digits.count < width && !fill.isEmpty
            ? String(repeating: fill, count: width - digits.count)
            : ""
        return (value < 0 ? "-" : "") + padding + digits
    }

    private static func dayOfYear(_ fields: MermaidGanttTime.Fields) -> Int {
        MermaidGanttTime.days(year: fields.year, month: fields.month, day: fields.day)
            - MermaidGanttTime.days(year: fields.year, month: 1, day: 1) + 1
    }

    /// `%U` and `%W`: weeks starting on `firstWeekday` since the one holding the last day of the
    /// year before, d3's `timeSunday.count(timeYear(d) - 1, d)`.
    private static func weekNumber(_ fields: MermaidGanttTime.Fields, firstWeekday: Int) -> Int {
        let today = MermaidGanttTime.days(year: fields.year, month: fields.month, day: fields.day)
        let lastOfBefore = MermaidGanttTime.days(year: fields.year, month: 1, day: 1) - 1
        return (weekFloor(today, firstWeekday) - weekFloor(lastOfBefore, firstWeekday)) / 7
    }

    private static func weekFloor(_ days: Int, _ firstWeekday: Int) -> Int {
        days - MermaidGanttTime.floorModulo(days + 4 - firstWeekday, 7)
    }

    /// The Thursday of the ISO week holding `time`, as days: d3's `dISO`.
    private static func isoThursday(_ time: Double) -> Int {
        let fields = MermaidGanttTime.fields(time)
        let days = MermaidGanttTime.days(year: fields.year, month: fields.month, day: fields.day)
        let weekday = fields.weekday
        return weekday >= 4 || weekday == 0
            ? weekFloor(days, 4)
            : weekFloor(days, 4) + 7
    }

    private static func isoWeekYear(_ time: Double) -> Int {
        MermaidGanttTime.civil(isoThursday(time)).year
    }

    /// `%V`: d3's `timeThursday.count(timeYear(d), d) + (timeYear(d).getDay() === 4)` on `dISO`.
    private static func isoWeek(_ time: Double) -> Int {
        let thursday = isoThursday(time)
        let year = MermaidGanttTime.civil(thursday).year
        let januaryFirst = MermaidGanttTime.days(year: year, month: 1, day: 1)
        let firstIsThursday = MermaidGanttTime.floorModulo(januaryFirst + 4, 7) == 4
        return (thursday - weekFloor(januaryFirst, 4)) / 7 + (firstIsThursday ? 1 : 0)
    }

    private static func instantMilliseconds(_ time: Double, _ zone: TimeZone) -> Double {
        MermaidGanttTime.instant(time, in: zone).timeIntervalSince1970 * 1000
    }

    /// `%Z`: `+0200`.
    private static func offset(_ time: Double, _ zone: TimeZone) -> String {
        let minutes = zone.secondsFromGMT(for: MermaidGanttTime.instant(time, in: zone)) / 60
        return (minutes < 0 ? "-" : "+") + padded(abs(minutes) / 60, "0", 2)
            + padded(abs(minutes) % 60, "0", 2)
    }
}
