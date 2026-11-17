import Foundation

/// A gantt fence's statements, read as Mermaid 12.3's grammar reads them (PLAN.md §M39 ▸ Slice 15).
///
/// One statement a line and no `;` split, as the grammar has none: a value stops at `;` or `#`
/// (`dateFormat YYYY-MM-DD # note`), and the rest of the line is not another statement. Keywords
/// are read in any case, as the lexer is case-insensitive, and a keyword needs a space after it, so
/// a task called `title: x` is a task. A line that is none of them and has no `:` is the parse error
/// Mermaid would show, and the fence falls back to its source.
///
/// `displayMode compact` is front matter `config`, which M39 does not read (PLAN.md §M39), and a
/// `todayMarker` style string is the same configuration surface: only `off` is read from it.
enum MermaidGanttParser {
    private static let weekdays = [
        "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"
    ]

    static func parse(_ statements: [String]) -> MermaidGanttSource? {
        var source = MermaidGanttSource()
        var section = ""
        var inDescription = false
        for statement in statements {
            if inDescription {
                inDescription = !statement.contains("}")
                continue
            }
            let lowered = statement.lowercased()
            if lowered.hasPrefix("accdescr"), statement.dropFirst(8).trimmingCharacters(
                in: .whitespaces
            ).hasPrefix("{") {
                inDescription = !statement.contains("}")
                continue
            }
            if lowered.hasPrefix("acctitle"), statement.dropFirst(8).trimmingCharacters(
                in: .whitespaces
            ).hasPrefix(":") {
                continue
            }
            if lowered.hasPrefix("accdescr"), statement.dropFirst(8).trimmingCharacters(
                in: .whitespaces
            ).hasPrefix(":") {
                continue
            }
            if let value = value(of: "section", in: statement, cut: false) {
                section = value
            } else if let value = value(of: "title", in: statement, cut: false) {
                source.title = value
            } else if setting(statement, lowered: lowered, into: &source) {
                continue
            } else if lowered.hasPrefix("click"), lowered.dropFirst(5).first?.isWhitespace == true {
                if !source.undrawn.contains("click") { source.undrawn.append("click") }
            } else if let colon = statement.firstIndex(of: ":") {
                let data = statement[statement.index(after: colon)...]
                    .prefix { $0 != "#" && $0 != ";" }
                guard !data.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                // As written: Mermaid sets a task's name as text, so `&lt;` stays four characters.
                source.tasks.append(MermaidGanttSource.Task(
                    name: String(statement[..<colon]).trimmingCharacters(in: .whitespaces),
                    section: section,
                    data: String(data)
                ))
            } else {
                return nil
            }
        }
        return source
    }

    /// A setting statement read into `source`; `false` when `statement` is not one.
    private static func setting(
        _ statement: String,
        lowered: String,
        into source: inout MermaidGanttSource
    ) -> Bool {
        if let value = value(of: "dateFormat", in: statement) {
            source.dateFormat = value
        } else if let value = value(of: "axisFormat", in: statement) {
            source.axisFormat = value
        } else if let value = value(of: "tickInterval", in: statement) {
            source.tickInterval = value
        } else if let value = value(of: "excludes", in: statement) {
            source.excludes = merged(source.excludes, value)
        } else if let value = value(of: "includes", in: statement) {
            source.includes = merged(source.includes, value)
        } else if let value = value(of: "todayMarker", in: statement, cut: false) {
            source.todayMarker = String(value.prefix { $0 != ";" })
        } else if lowered == "inclusiveenddates" {
            source.inclusiveEndDates = true
        } else if lowered == "topaxis" {
            source.topAxis = true
        } else if let day = value(of: "weekday", in: statement)?.lowercased(), weekdays.contains(day) {
            source.weekday = day
        } else if let day = value(of: "weekend", in: statement)?.lowercased(),
                  day == "friday" || day == "saturday" {
            source.weekend = day
        } else {
            return false
        }
        return true
    }

    /// The text after `keyword` and a space, cut at `#` or `;` unless `cut` is off, as each of
    /// Mermaid's lexer rules cuts it; `nil` when `statement` does not open with the keyword.
    private static func value(of keyword: String, in statement: String, cut: Bool = true) -> String? {
        guard statement.count > keyword.count,
              statement.prefix(keyword.count).lowercased() == keyword.lowercased(),
              statement.dropFirst(keyword.count).first?.isWhitespace == true
        else { return nil }
        let rest = statement.dropFirst(keyword.count)
        let value = cut ? rest.prefix { $0 != "#" && $0 != ";" } : rest
        return value.trimmingCharacters(in: .whitespaces)
    }

    /// `excludes` and `includes` add to what an earlier line listed, lowercased, split at spaces
    /// and commas.
    private static func merged(_ existing: [String], _ text: String) -> [String] {
        var result = existing
        for word in text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," })
            where !result.contains(String(word)) {
            result.append(String(word))
        }
        return result
    }
}

/// What the statements said, before any date is worked out.
struct MermaidGanttSource: Equatable {
    struct Task: Equatable {
        let name: String
        let section: String
        /// Everything after the `:`, as written.
        let data: String
    }

    var title: String?
    var dateFormat = ""
    var axisFormat = ""
    var tickInterval = ""
    var includes: [String] = []
    var excludes: [String] = []
    var todayMarker = ""
    var inclusiveEndDates = false
    var topAxis = false
    var weekday = "sunday"
    var weekend = "saturday"
    var tasks: [Task] = []
    var undrawn: [String] = []
}
