import Foundation

/// A gantt's `dateFormat`, read as Mermaid reads it: dayjs's tokens, parsed strictly (PLAN.md §M39 ▸
/// Slice 15).
///
/// Mermaid parses a date with `dayjs(text, format, true)`, and the `true` is the rule worth knowing:
/// a date is valid only when formatting what was read gives back the text exactly, so `2014-02-30`
/// rolls over to March and fails, and `2014-1-5` fails `YYYY-MM-DD`. The same formatter decides an
/// `excludes` date, which matches when the day formatted this way is one of the listed words.
///
/// The tokens are dayjs's English locale with the `customParseFormat` and `advancedFormat` plugins
/// Mermaid loads. One difference, and it is leniency: dayjs re-formats a `Z` offset in the *viewer's*
/// zone, so `10:00+00:00` passes its strict check only where the clocks read UTC, and `Z` nowhere;
/// here an offset is taken as written, and the instant is then turned into the local wall clock.
enum MermaidGanttDateFormat {
    enum Token: Equatable {
        case literal(String)
        case year4, year2
        case month1, month2, monthShort, monthLong
        case day1, day2, dayOrdinal
        case weekday1, weekdayMin, weekdayShort, weekdayLong
        case hour1, hour2, hour12, hour12Padded
        case minute1, minute2, second1, second2
        /// `S` and `SS` read tenths and hundredths, and format as the letters (dayjs formats only
        /// `SSS`), so a format holding them never passes the strict check, as in dayjs.
        case tenths, hundredths, milliseconds
        case meridiemUpper, meridiemLower
        case offsetColon, offsetPlain
        case quarter
    }

    private static let spellings: [(String, Token)] = [
        ("YYYY", .year4), ("YY", .year2),
        ("MMMM", .monthLong), ("MMM", .monthShort), ("MM", .month2), ("M", .month1),
        ("Do", .dayOrdinal), ("DD", .day2), ("D", .day1),
        ("dddd", .weekdayLong), ("ddd", .weekdayShort), ("dd", .weekdayMin), ("d", .weekday1),
        ("HH", .hour2), ("H", .hour1), ("hh", .hour12Padded), ("h", .hour12),
        ("mm", .minute2), ("m", .minute1), ("ss", .second2), ("s", .second1),
        ("SSS", .milliseconds), ("SS", .hundredths), ("S", .tenths),
        ("A", .meridiemUpper), ("a", .meridiemLower),
        ("ZZ", .offsetPlain), ("Z", .offsetColon),
        ("Q", .quarter)
    ]

    static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ]
    static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"
    ]

    /// `format` split into tokens: `[text]` is literal, and so is any character no token spells.
    static func tokens(_ format: String) -> [Token] {
        var tokens: [Token] = []
        var rest = Substring(format)
        func literal(_ text: Substring) {
            if case let .literal(previous)? = tokens.last {
                tokens[tokens.count - 1] = .literal(previous + text)
            } else {
                tokens.append(.literal(String(text)))
            }
        }
        while let first = rest.first {
            if first == "[", let close = rest.firstIndex(of: "]") {
                literal(rest[rest.index(after: rest.startIndex)..<close])
                rest = rest[rest.index(after: close)...]
            } else if let (spelling, token) = spellings.first(where: { rest.hasPrefix($0.0) }) {
                tokens.append(token)
                rest = rest.dropFirst(spelling.count)
            } else {
                literal(rest.prefix(1))
                rest = rest.dropFirst()
            }
        }
        return tokens
    }

    // MARK: - Formatting

    /// `fields` written in `format`. `offsetMinutes` is what `Z` writes, east of UTC positive.
    static func format(
        _ fields: MermaidGanttTime.Fields,
        _ format: String,
        offsetMinutes: Int = 0
    ) -> String {
        tokens(format).map { text($0, fields, offsetMinutes: offsetMinutes) }.joined()
    }

    static func text(
        _ token: Token,
        _ fields: MermaidGanttTime.Fields,
        offsetMinutes: Int
    ) -> String {
        if case let .literal(text) = token { return text }
        return dateText(token, fields) ?? nameText(token, fields)
            ?? clockText(token, fields) ?? partText(token, fields, offsetMinutes: offsetMinutes) ?? ""
    }

    private static func dateText(_ token: Token, _ fields: MermaidGanttTime.Fields) -> String? {
        switch token {
        case .year4: padded(fields.year, 4)
        case .year2: String(String(fields.year).suffix(2))
        case .month1: String(fields.month)
        case .month2: padded(fields.month, 2)
        case .day1: String(fields.day)
        case .day2: padded(fields.day, 2)
        case .quarter: String((fields.month - 1) / 3 + 1)
        default: nil
        }
    }

    private static func nameText(_ token: Token, _ fields: MermaidGanttTime.Fields) -> String? {
        switch token {
        case .monthShort: String(monthNames[fields.month - 1].prefix(3))
        case .monthLong: monthNames[fields.month - 1]
        case .dayOrdinal: ordinal(fields.day)
        case .weekday1: String(fields.weekday)
        case .weekdayMin: String(weekdayNames[fields.weekday].prefix(2))
        case .weekdayShort: String(weekdayNames[fields.weekday].prefix(3))
        case .weekdayLong: weekdayNames[fields.weekday]
        default: nil
        }
    }

    private static func clockText(_ token: Token, _ fields: MermaidGanttTime.Fields) -> String? {
        let twelve = fields.hour % 12 == 0 ? 12 : fields.hour % 12
        switch token {
        case .hour1: return String(fields.hour)
        case .hour2: return padded(fields.hour, 2)
        case .hour12: return String(twelve)
        case .hour12Padded: return padded(twelve, 2)
        case .minute1: return String(fields.minute)
        case .minute2: return padded(fields.minute, 2)
        case .second1: return String(fields.second)
        case .second2: return padded(fields.second, 2)
        default: return nil
        }
    }

    private static func partText(
        _ token: Token,
        _ fields: MermaidGanttTime.Fields,
        offsetMinutes: Int
    ) -> String? {
        switch token {
        case .tenths: "S"
        case .hundredths: "SS"
        case .milliseconds: padded(fields.millisecond, 3)
        case .meridiemUpper: fields.hour < 12 ? "AM" : "PM"
        case .meridiemLower: fields.hour < 12 ? "am" : "pm"
        case .offsetColon, .offsetPlain: offset(offsetMinutes, colon: token == .offsetColon)
        default: nil
        }
    }

    /// dayjs's English ordinal: `1st`, `2nd`, `3rd`, `4th`, `11th`, `21st`.
    static func ordinal(_ number: Int) -> String {
        let suffixes = ["th", "st", "nd", "rd"]
        let lastTwo = number % 100
        if lastTwo >= 20, (lastTwo - 20) % 10 < 4 { return "\(number)\(suffixes[(lastTwo - 20) % 10])" }
        if lastTwo < 4 { return "\(number)\(suffixes[lastTwo])" }
        return "\(number)th"
    }

    static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - digits.count))
        return (value < 0 ? "-" : "") + padding + digits
    }

    private static func offset(_ minutes: Int, colon: Bool) -> String {
        let sign = minutes < 0 ? "-" : "+"
        let hours = padded(abs(minutes) / 60, 2)
        return sign + hours + (colon ? ":" : "") + padded(abs(minutes) % 60, 2)
    }
}
