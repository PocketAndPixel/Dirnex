import Foundation

/// The second chance Mermaid gives a task's start: JavaScript's `new Date(text)` (PLAN.md §M39 ▸
/// Slice 15).
///
/// When a start does not parse strictly in the `dateFormat`, Mermaid hands the text to `Date`, so
/// `2014-01-02 10:00` under `YYYY-MM-DD` still starts a task at ten. Only the ISO forms are read
/// here, with a space allowed for the `T`, as both WebKit and V8 allow it: they are what a file with
/// a `dateFormat` that does not fit its own dates actually holds. The browsers' looser readings
/// (`Jan 2 2014`, `1/2/2014`) differ between engines, and a start in one of them fails the diagram.
///
/// JavaScript's own rule stays: a date alone is midnight **in UTC**, which a wall clock east of
/// London shows as that morning, and a date with a time and no offset is local. A year past
/// ±10 000 is refused, as Mermaid refuses it.
enum MermaidGanttScriptDate {
    static func wallClock(_ text: String, in zone: TimeZone) -> Double? {
        var cursor = Cursor(characters: Array(text))
        guard var fields = date(&cursor) else { return nil }
        let hasTime = cursor.take("T") || cursor.take(" ")
        if hasTime {
            guard clock(&cursor, into: &fields) else { return nil }
        }
        guard let offset = offset(&cursor, afterTime: hasTime), cursor.isAtEnd else { return nil }

        let time = MermaidGanttTime.time(fields)
        // A date alone is UTC's midnight; a time with no offset is the local one.
        let minutes: Int
        switch (hasTime, offset) {
        case (false, _): minutes = 0
        case (true, .local): return time
        case let (true, .minutes(east)): minutes = east
        }
        let instant = Date(timeIntervalSince1970: time / 1000 - Double(minutes * 60))
        return MermaidGanttTime.wallClock(instant, in: zone)
    }

    private struct Cursor {
        let characters: [Character]
        var position = 0

        var isAtEnd: Bool { position == characters.count }
        var next: Character? { position < characters.count ? characters[position] : nil }

        mutating func take(_ character: Character) -> Bool {
            guard next == character else { return false }
            position += 1
            return true
        }

        mutating func number(_ count: Int) -> Int? {
            guard position + count <= characters.count else { return nil }
            let run = characters[position..<position + count]
            guard run.allSatisfy(\.isASCIIDigitCharacter) else { return nil }
            position += count
            return Int(String(run))
        }

        mutating func digits() -> String {
            let start = position
            while let next, next.isASCIIDigitCharacter { position += 1 }
            return String(characters[start..<position])
        }
    }

    /// `YYYY`, `YYYY-MM` or `YYYY-MM-DD`, a six-digit signed year allowed.
    private static func date(_ cursor: inout Cursor) -> MermaidGanttTime.Fields? {
        var sign = 1
        var yearDigits = 4
        if cursor.position == 0, cursor.next == "+" || cursor.next == "-" {
            sign = cursor.next == "-" ? -1 : 1
            cursor.position += 1
            yearDigits = 6
        }
        guard let year = cursor.number(yearDigits).map({ $0 * sign }), abs(year) <= 10000 else {
            return nil
        }
        var fields = MermaidGanttTime.Fields(year: year, month: 1, day: 1)
        guard cursor.take("-") else { return fields }
        guard let month = cursor.number(2), (1...12).contains(month) else { return nil }
        fields.month = month
        guard cursor.take("-") else { return fields }
        guard let day = cursor.number(2),
              (1...MermaidGanttTime.daysInMonth(year: year, month: month)).contains(day)
        else { return nil }
        fields.day = day
        return fields
    }

    /// `HH:mm`, `HH:mm:ss` or `HH:mm:ss.sss`; `24:00` and nothing past it.
    private static func clock(_ cursor: inout Cursor, into fields: inout MermaidGanttTime.Fields) -> Bool {
        guard let hour = cursor.number(2), cursor.take(":"), let minute = cursor.number(2),
              hour <= 24, minute <= 59
        else { return false }
        fields.hour = hour
        fields.minute = minute
        if cursor.take(":") {
            guard let second = cursor.number(2), second <= 59 else { return false }
            fields.second = second
            if cursor.take(".") {
                let digits = cursor.digits().prefix(3)
                guard !digits.isEmpty else { return false }
                fields.millisecond = Int(digits.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
            }
        }
        return hour < 24 || fields.minute + fields.second + fields.millisecond == 0
    }

    private enum Offset {
        /// None written: the local wall clock.
        case local
        /// Minutes east of UTC.
        case minutes(Int)
    }

    /// `Z`, or `±HH:mm` after a time; `nil` when what follows is not an offset.
    private static func offset(_ cursor: inout Cursor, afterTime: Bool) -> Offset? {
        if cursor.take("Z") { return .minutes(0) }
        guard afterTime, let sign = cursor.next, sign == "+" || sign == "-" else { return .local }
        cursor.position += 1
        guard let hours = cursor.number(2) else { return nil }
        _ = cursor.take(":")
        guard let minutes = cursor.number(2) else { return nil }
        return .minutes((hours * 60 + minutes) * (sign == "-" ? -1 : 1))
    }
}
