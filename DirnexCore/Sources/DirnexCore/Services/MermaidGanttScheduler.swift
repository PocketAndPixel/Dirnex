import Foundation

/// The working state of `MermaidGanttSchedule`'s passes (PLAN.md §M39 ▸ Slice 15): each task's data
/// read once, then its start and end worked out again on every pass, as Mermaid's `compileTasks`
/// works them out.
struct MermaidGanttScheduler {
    /// Where a task starts: where the task above ends, or what its data says.
    enum Start {
        case previous(String?)
        case expression(String)
    }

    struct Entry {
        let task: MermaidGanttSource.Task
        let id: String
        let startSpec: Start
        let endText: String
        let tags: Set<String>
        var start: Double?
        var end: Double?
        var drawnEnd: Double?
        var isPlaced = false
    }

    let source: MermaidGanttSource
    let clock: MermaidGanttClock
    let dateFormat: String
    let today: MermaidGanttTime.Fields
    var entries: [Entry] = []
    var index: [String: Int] = [:]

    init(source: MermaidGanttSource, clock: MermaidGanttClock) {
        self.source = source
        self.clock = clock
        let format = source.dateFormat.trimmingCharacters(in: .whitespaces)
        dateFormat = format.isEmpty ? "YYYY-MM-DD" : format
        today = clock.today
    }

    private static let tagNames = ["active", "done", "crit", "milestone", "vert"]

    mutating func add(_ tasks: [MermaidGanttSource.Task]) throws {
        var automatic = 0
        var previous: String?
        for task in tasks {
            var fields = task.data.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            var tags: Set<String> = []
            var found = true
            while found {
                found = false
                for tag in Self.tagNames {
                    guard let first = fields.first else { throw MermaidGanttSchedule.Failure.badData(
                        task.data
                    ) }
                    if first.trimmingCharacters(in: .whitespaces) == tag {
                        tags.insert(tag)
                        fields.removeFirst()
                        found = true
                    }
                }
            }
            fields = fields.map { $0.trimmingCharacters(in: .whitespaces) }
            let id: String
            let start: Start
            switch fields.count {
            case 1, 2:
                automatic += 1
                id = "task\(automatic)"
                start = fields.count == 1 ? .previous(previous) : .expression(fields[0])
            case 3:
                id = fields[0]
                start = .expression(fields[1])
            default:
                throw MermaidGanttSchedule.Failure.badData(task.data)
            }
            index[id] = entries.count
            entries.append(Entry(
                task: task,
                id: id,
                startSpec: start,
                endText: fields[fields.count - 1],
                tags: tags
            ))
            previous = id
        }
    }

    /// One of Mermaid's passes over every task, in order: whether all of them are placed.
    mutating func pass() throws -> Bool {
        var allPlaced = true
        for position in entries.indices {
            switch entries[position].startSpec {
            case let .previous(id):
                guard let id, let before = index[id] else {
                    throw MermaidGanttSchedule.Failure.noPreviousTask(entries[position].task.name)
                }
                entries[position].start = entries[before].end
            case let .expression(text):
                if let start = try startTime(text) { entries[position].start = start }
            }
            if let start = entries[position].start {
                let end = endTime(from: start, entries[position].endText)
                entries[position].end = end
                if end != nil {
                    entries[position].isPlaced = true
                    try exclude(at: position)
                }
            }
            allPlaced = allPlaced && entries[position].isPlaced
        }
        return allPlaced
    }

    // MARK: Starts and ends

    func startTime(_ text: String) throws -> Double? {
        if dateFormat == "x" || dateFormat == "X", !text.isEmpty,
           text.allSatisfy(\.isASCIIDigitCharacter), let milliseconds = Double(text) {
            return MermaidGanttTime.wallClock(
                Date(timeIntervalSince1970: milliseconds / 1000),
                in: clock.timeZone
            )
        }
        if let ids = references(after: "after", in: text) {
            var latest: Entry?
            for id in ids {
                guard let found = index[id].map({ entries[$0] }) else { continue }
                if let current = latest {
                    if let end = found.end, let best = current.end, end > best { latest = found }
                } else {
                    latest = found
                }
            }
            return latest.map(\.end) ?? midnightToday
        }
        if let parsed = strict(text) { return parsed }
        if let fallback = MermaidGanttScriptDate.wallClock(text, in: clock.timeZone) {
            return fallback
        }
        throw MermaidGanttSchedule.Failure.invalidDate(text)
    }

    func endTime(from start: Double, _ text: String) -> Double? {
        if let ids = references(after: "until", in: text) {
            var earliest: Entry?
            for id in ids {
                guard let found = index[id].map({ entries[$0] }) else { continue }
                if let current = earliest {
                    if let begin = found.start, let best = current.start, begin < best {
                        earliest = found
                    }
                } else {
                    earliest = found
                }
            }
            return earliest.map(\.start) ?? midnightToday
        }
        if let date = strict(text) {
            return source.inclusiveEndDates ? MermaidGanttTime.adding(1, .day, to: date) : date
        }
        guard let (value, unit) = Self.duration(text) else { return start }
        return MermaidGanttTime.adding(value, unit, to: start)
    }

    /// The ids after `keyword` and a space, from Mermaid's `^after\s+([\d\w- ]+)`.
    func references(after keyword: String, in text: String) -> [String]? {
        guard text.hasPrefix(keyword),
              let space = text.dropFirst(keyword.count).first, space.isWhitespace
        else { return nil }
        let rest = text.dropFirst(keyword.count).drop(while: \.isWhitespace)
        let ids = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "_- ".contains($0)) }
        guard !ids.isEmpty else { return nil }
        return ids.split(separator: " ").map(String.init)
    }

    /// `3d`, `2.5w`, `30m`, `1M` (`m` is minutes, `M` months), `500ms`.
    static func duration(_ text: String) -> (Double, MermaidGanttTime.Unit)? {
        let number = text.prefix { $0.isASCIIDigitCharacter || $0 == "." }
        let suffix = text.dropFirst(number.count)
        guard let value = Double(number), number.first != ".", number.last != ".",
              number.filter({ $0 == "." }).count <= 1,
              let unit = MermaidGanttTime.Unit(rawValue: String(suffix))
        else { return nil }
        return (value, unit)
    }

    var midnightToday: Double? {
        clock.wallClock.map(MermaidGanttTime.startOfDay)
    }

    func strict(_ text: String) -> Double? {
        strict(text, format: dateFormat)
    }

    func strict(_ text: String, format: String) -> Double? {
        guard let parsed = MermaidGanttDateFormat.parse(text, format: format, today: today) else {
            return nil
        }
        let time = MermaidGanttTime.time(parsed.fields)
        guard let offset = parsed.offsetMinutes else { return time }
        let instant = Date(timeIntervalSince1970: (time / 1000) - Double(offset * 60))
        return MermaidGanttTime.wallClock(instant, in: clock.timeZone)
    }
}
