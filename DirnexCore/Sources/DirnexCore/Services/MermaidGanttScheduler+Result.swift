import Foundation

/// The days `excludes` takes out, and the chart the passes leave (PLAN.md §M39 ▸ Slice 15).
extension MermaidGanttScheduler {
    // MARK: Excluded days

    /// Mermaid's `checkTaskDates` and `fixTaskDates`: walk the days after the start and push
    /// the end a day for each excluded one, while the drawn end is the last end seen before
    /// an excluded day.
    mutating func exclude(at position: Int) throws {
        let entry = entries[position]
        guard !source.excludes.isEmpty, let start = entry.start, var end = entry.end,
              strict(entry.endText, format: "YYYY-MM-DD") == nil
        else { return }
        var day = MermaidGanttTime.adding(1, .day, to: start)
        let limit = MermaidGanttTime.adding(10000, .day, to: end)
        var excluded = false
        var drawnEnd: Double?
        while day <= end {
            if !excluded { drawnEnd = end }
            excluded = isExcluded(day)
            if excluded {
                end = MermaidGanttTime.adding(1, .day, to: end)
                if end > limit { throw MermaidGanttSchedule.Failure.everyDayExcluded }
            }
            day = MermaidGanttTime.adding(1, .day, to: day)
        }
        entries[position].end = end
        entries[position].drawnEnd = drawnEnd
    }

    /// Mermaid's `isInvalidDate`: `includes` wins; then `weekends` (Saturday and Sunday, or
    /// Friday and Saturday after `weekend friday`), a weekday's name, or the day as the
    /// `dateFormat` or as `YYYY-MM-DD` writes it.
    func isExcluded(_ time: Double) -> Bool {
        let fields = MermaidGanttTime.fields(time)
        let formatted = MermaidGanttDateFormat.format(
            fields,
            dateFormat,
            offsetMinutes: offset(time)
        )
        let dateOnly = MermaidGanttDateFormat.format(fields, "YYYY-MM-DD")
        if source.includes.contains(formatted) || source.includes.contains(dateOnly) {
            return false
        }
        let weekendStart = source.weekend == "friday" ? 5 : 6
        if source.excludes.contains("weekends"),
           fields.weekday == weekendStart || fields.weekday == (weekendStart + 1) % 7 {
            return true
        }
        if source.excludes.contains(
            MermaidGanttDateFormat.weekdayNames[fields.weekday].lowercased()
        ) {
            return true
        }
        return source.excludes.contains(formatted) || source.excludes.contains(dateOnly)
    }

    func offset(_ time: Double) -> Int {
        clock.timeZone.secondsFromGMT(for: MermaidGanttTime.instant(time, in: clock.timeZone)) / 60
    }

    // MARK: The result

    var gantt: MermaidGantt {
        var row = 0
        let tasks = entries.map { entry -> MermaidGantt.Task in
            let isVertical = entry.tags.contains("vert")
            defer { if !isVertical { row += 1 } }
            return MermaidGantt.Task(
                name: entry.task.name,
                id: entry.id,
                section: entry.task.section,
                row: isVertical ? nil : row,
                start: entry.start,
                end: entry.end,
                drawnEnd: entry.drawnEnd,
                isActive: entry.tags.contains("active"),
                isDone: entry.tags.contains("done"),
                isCritical: entry.tags.contains("crit"),
                isMilestone: entry.tags.contains("milestone"),
                isVertical: isVertical
            )
        }
        let marker = source.todayMarker.trimmingCharacters(in: .whitespaces)
        return MermaidGantt(
            title: source.title,
            tasks: tasks,
            axisFormat: axisFormat,
            tickInterval: tickInterval,
            weekStart: MermaidGanttDateFormat.weekdayNames
                .firstIndex { $0.lowercased() == source.weekday } ?? 0,
            hasTopAxis: source.topAxis,
            excludedRuns: excludedRuns(tasks),
            today: marker == "off" ? nil : clock.wallClock,
            undrawn: source.undrawn
        )
    }

    var axisFormat: String {
        let written = source.axisFormat.trimmingCharacters(in: .whitespaces)
        if !written.isEmpty { return written }
        return dateFormat == "D" ? "%d" : "%Y-%m-%d"
    }

    /// Mermaid's `^([1-9]\d*)(millisecond|second|minute|hour|day|week|month)$`.
    var tickInterval: MermaidGanttTickInterval? {
        let text = source.tickInterval
        let digits = text.prefix(while: \.isASCIIDigitCharacter)
        guard digits.first != "0", let count = Int(digits),
              let unit = MermaidGanttTickInterval.Unit(
                  rawValue: String(text.dropFirst(digits.count))
              )
        else { return nil }
        return MermaidGanttTickInterval(count: count, unit: unit)
    }

    /// The excluded days between the chart's first start and last end, as Mermaid shades them,
    /// and none over more than five years, where Mermaid draws none either. A run at the very
    /// end is shaded too, which Mermaid's loop forgets.
    func excludedRuns(_ tasks: [MermaidGantt.Task]) -> [ClosedRange<Double>] {
        guard !source.excludes.isEmpty || !source.includes.isEmpty,
              let first = tasks.compactMap(\.start).min(),
              let last = tasks.compactMap(\.end).max(),
              last < MermaidGanttTime.adding(6, .year, to: first)
        else { return [] }
        var runs: [ClosedRange<Double>] = []
        var open: Double?
        var day = first
        while day <= last {
            let midnight = MermaidGanttTime.startOfDay(day)
            if isExcluded(day) {
                if open == nil { open = midnight }
            } else if let start = open {
                runs.append(start...midnight)
                open = nil
            }
            day = MermaidGanttTime.adding(1, .day, to: day)
        }
        if let start = open {
            runs.append(start...MermaidGanttTime.startOfDay(day))
        }
        return runs
    }
}
