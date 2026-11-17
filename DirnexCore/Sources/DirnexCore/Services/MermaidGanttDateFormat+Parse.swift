import Foundation

/// A strict parse in a gantt's `dateFormat` (PLAN.md §M39 ▸ Slice 15): each token reads what dayjs's
/// pattern for it reads, from where the last one stopped, and the result counts only when writing it
/// back in the same format gives the text again.
extension MermaidGanttDateFormat {
    /// What a strict parse read: a wall clock, and the offset when the text gave one.
    struct Parsed: Equatable {
        var fields: MermaidGanttTime.Fields
        /// Minutes east of UTC, when the format holds `Z` or `ZZ`.
        var offsetMinutes: Int?
    }

    /// `text` read in `format`, or `nil` unless formatting the result gives `text` back.
    ///
    /// A part the format does not name comes from `today`, as dayjs takes it from `new Date()`: a
    /// format with no year takes today's, with neither year nor month today's date too, and a
    /// year alone means January the first.
    static func parse(
        _ text: String,
        format: String,
        today: MermaidGanttTime.Fields
    ) -> Parsed? {
        let tokens = Self.tokens(format)
        guard !tokens.isEmpty, var read = Self.read(text, tokens: tokens) else { return nil }
        if let afternoon = read.afternoon, let hour = read.hour {
            read.hour = afternoon ? (hour < 12 ? hour + 12 : hour) : (hour == 12 ? 0 : hour)
        }
        let year = read.year ?? today.year
        let month = read.month ?? (read.year != nil ? 1 : today.month)
        let day = read.day ?? (read.year == nil && read.month == nil ? today.day : 1)
        let fields = MermaidGanttTime.fields(MermaidGanttTime.time(MermaidGanttTime.Fields(
            year: year,
            month: month,
            day: day,
            hour: read.hour ?? 0,
            minute: read.minute ?? 0,
            second: read.second ?? 0,
            millisecond: read.millisecond ?? 0
        )))
        let check = tokens.map { token in
            if token == .offsetColon || token == .offsetPlain, let written = read.offsetText {
                return written
            }
            return Self.text(token, fields, offsetMinutes: read.offset ?? 0)
        }.joined()
        guard check == text else { return nil }
        return Parsed(fields: fields, offsetMinutes: read.offset)
    }

    private struct Read {
        var year: Int?
        var month: Int?
        var day: Int?
        var hour: Int?
        var minute: Int?
        var second: Int?
        var millisecond: Int?
        var afternoon: Bool?
        var offset: Int?
        /// The offset as the text wrote it (`Z`, `+0200`), which the strict check writes back.
        var offsetText: String?
    }

    private static func read(_ text: String, tokens: [Token]) -> Read? {
        var read = Read()
        var rest = Substring(text)
        for token in tokens {
            if case let .literal(literal) = token {
                guard rest.hasPrefix(literal) else { return nil }
                rest = rest.dropFirst(literal.count)
                continue
            }
            guard let piece = piece(of: rest, for: token) else { return nil }
            rest = rest.dropFirst(piece.count)
            guard store(piece, token: token, into: &read) else { return nil }
        }
        return rest.isEmpty ? read : nil
    }

    /// The text `token` takes from the front of `rest`, by dayjs's own patterns: one or two digits
    /// for most numbers, exactly four for `YYYY` and two for `MM` and `DD`, a word for a name.
    private static func piece(of rest: Substring, for token: Token) -> Substring? {
        func digits(_ least: Int, _ most: Int) -> Substring? {
            let run = rest.prefix(while: \.isASCIIDigitCharacter).prefix(most)
            return run.count >= least ? run : nil
        }
        switch token {
        case .year4: return digits(4, 4)
        case .year2, .month2, .day2, .hundredths: return digits(2, 2)
        case .month1, .day1, .hour1, .hour2, .hour12, .hour12Padded,
             .minute1, .minute2, .second1, .second2: return digits(1, 2)
        case .tenths, .quarter, .weekday1: return digits(1, 1)
        case .milliseconds: return digits(3, 3)
        case .monthShort, .monthLong, .dayOrdinal, .meridiemUpper, .meridiemLower,
             .weekdayMin, .weekdayShort, .weekdayLong:
            let leading = rest.prefix(while: \.isASCIIDigitCharacter)
            let word = rest.dropFirst(leading.count).prefix { !$0.isWordBreak }
            return word.isEmpty ? nil : rest.prefix(leading.count + word.count)
        case .offsetColon, .offsetPlain:
            if rest.hasPrefix("Z") { return rest.prefix(1) }
            guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
            let body = rest.dropFirst()
            let hours = body.prefix(while: \.isASCIIDigitCharacter).prefix(2)
            guard hours.count == 2 else { return nil }
            var after = body.dropFirst(2)
            var length = 3
            if after.hasPrefix(":") {
                after = after.dropFirst()
                length += 1
            }
            let minutes = after.prefix(while: \.isASCIIDigitCharacter).prefix(2)
            if minutes.count == 2 { return rest.prefix(length + 2) }
            return rest.prefix(3)
        case .literal: return nil
        }
    }

    private static func store(_ piece: Substring, token: Token, into read: inout Read) -> Bool {
        let number = Int(piece.prefix(while: \.isASCIIDigitCharacter))
        if storeNumber(number, token: token, into: &read) { return true }
        switch token {
        case .monthShort, .monthLong:
            let length = token == .monthShort ? 3 : Int.max
            guard let index = monthNames.firstIndex(where: { $0.prefix(length) == piece }) else {
                return false
            }
            read.month = index + 1
        case .meridiemUpper: read.afternoon = piece == "PM"
        case .meridiemLower: read.afternoon = piece == "pm"
        case .offsetColon, .offsetPlain:
            read.offset = offsetMinutes(piece)
            read.offsetText = String(piece)
        default:
            // A weekday is read and then checked by the strict format, which writes the real one.
            break
        }
        return true
    }

    /// The tokens that read a number into one field; `false` for any other.
    private static func storeNumber(_ number: Int?, token: Token, into read: inout Read) -> Bool {
        switch token {
        case .year4: read.year = number
        case .year2: read.year = number.map { $0 + ($0 > 68 ? 1900 : 2000) }
        case .month1, .month2: read.month = number
        case .quarter: read.month = number.map { ($0 - 1) * 3 + 1 }
        case .day1, .day2, .dayOrdinal: read.day = number
        case .hour1, .hour2, .hour12, .hour12Padded: read.hour = number
        case .minute1, .minute2: read.minute = number
        case .second1, .second2: read.second = number
        case .tenths: read.millisecond = number.map { $0 * 100 }
        case .hundredths: read.millisecond = number.map { $0 * 10 }
        case .milliseconds: read.millisecond = number
        default: return false
        }
        return true
    }

    private static func offsetMinutes(_ piece: Substring) -> Int {
        guard piece != "Z" else { return 0 }
        let digits = piece.filter(\.isASCIIDigitCharacter)
        let hours = Int(digits.prefix(2)) ?? 0
        let minutes = Int(digits.dropFirst(2)) ?? 0
        let total = hours * 60 + minutes
        return piece.hasPrefix("-") ? -total : total
    }
}

extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }

    /// dayjs's `matchWord` stops a name at a digit, whitespace or one of `-_:/,()`.
    fileprivate var isWordBreak: Bool {
        isASCIIDigitCharacter || isWhitespace || "-_:/,()".contains(self)
    }
}
