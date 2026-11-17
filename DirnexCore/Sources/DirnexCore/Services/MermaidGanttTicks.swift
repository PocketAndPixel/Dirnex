import Foundation

/// Where a gantt's axis puts its ticks: d3's time scale, which Mermaid draws the axis with (PLAN.md
/// §M39 ▸ Slice 15).
///
/// With no `tickInterval`, d3 asks for about ten ticks and takes the one of its eighteen steps
/// (one second up to three months, then whole years) nearest a tenth of the span, so 54 days get a
/// tick every Sunday and three days one every six hours. A tick falls on a boundary of its unit and
/// on a multiple of the step *within* the next unit up, d3's `every`: two-day ticks are the 1st, 3rd,
/// 5th of each month, and three-month ticks January, April, July and October. Weeks are counted
/// from the week of 1970-01-01 instead, having no larger unit.
///
/// `tickInterval 1week` names the step itself, a week starting on the `weekday` the file gives.
/// Mermaid drops a named step that would draw more than 10 000 ticks, and so does this.
enum MermaidGanttTicks {
    static let maximumNamedTicks = 10000

    /// The ticks between `start` and `stop`, both included, as wall-clock times.
    static func ticks(
        from start: Double,
        to stop: Double,
        named: MermaidGanttTickInterval?,
        weekStart: Int
    ) -> [Double] {
        guard stop >= start else { return [] }
        if let named, estimatedCount(start, stop, named) <= Double(maximumNamedTicks),
           let interval = interval(named.unit, weekStart: weekStart).every(named.count) {
            return interval.range(start, stop + 1)
        }
        return automatic(start, stop)?.range(start, stop + 1) ?? []
    }

    /// Mermaid's estimate, with dayjs's month of 365/12 days.
    private static func estimatedCount(
        _ start: Double,
        _ stop: Double,
        _ named: MermaidGanttTickInterval
    ) -> Double {
        let day = MermaidGanttTime.millisecondsPerDay
        let unit: Double = switch named.unit {
        case .millisecond: 1
        case .second: 1000
        case .minute: 60000
        case .hour: 3_600_000
        case .day: day
        case .week: 7 * day
        case .month: day * 365 / 12
        }
        return ((stop - start) / (unit * Double(named.count))).rounded(.up)
    }

    // MARK: - d3's automatic choice

    private static let second = 1000.0
    private static let minute = 60000.0
    private static let hour = 3_600_000.0
    private static let day = MermaidGanttTime.millisecondsPerDay

    /// One of d3's eighteen steps: `count` `unit`s, `length` long; no unit is d3's years.
    private struct Step {
        let unit: MermaidGanttTickInterval.Unit?
        let count: Int
        let length: Double

        init(_ unit: MermaidGanttTickInterval.Unit?, _ count: Int, _ length: Double) {
            self.unit = unit
            self.count = count
            self.length = length
        }
    }

    private static let steps: [Step] = [
        Step(.second, 1, second), Step(.second, 5, 5 * second), Step(.second, 15, 15 * second),
        Step(.second, 30, 30 * second), Step(.minute, 1, minute), Step(.minute, 5, 5 * minute),
        Step(.minute, 15, 15 * minute), Step(.minute, 30, 30 * minute), Step(.hour, 1, hour),
        Step(.hour, 3, 3 * hour), Step(.hour, 6, 6 * hour), Step(.hour, 12, 12 * hour),
        Step(.day, 1, day), Step(.day, 2, 2 * day), Step(.week, 1, 7 * day),
        Step(.month, 1, 30 * day), Step(.month, 3, 90 * day), Step(nil, 1, 365 * day)
    ]

    /// d3's `tickInterval(start, stop, 10)`.
    static func automatic(_ start: Double, _ stop: Double) -> Interval? {
        let count = 10.0
        let target = abs(stop - start) / count
        let index = steps.firstIndex { $0.length > target } ?? steps.count
        if index == steps.count {
            let years = tickStep(start / (365 * day), stop / (365 * day), count)
            return yearInterval(every: years)
        }
        if index == 0 {
            return millisecondInterval(every: max(tickStep(start, stop, count), 1))
        }
        let pick = target / steps[index - 1].length < steps[index].length / target ? index - 1 : index
        guard let unit = steps[pick].unit else { return yearInterval(every: 1) }
        return interval(unit, weekStart: 0).every(steps[pick].count)
    }

    /// d3-array's `tickStep`: 1, 2 or 5 times a power of ten.
    static func tickStep(_ start: Double, _ stop: Double, _ count: Double) -> Double {
        let reverse = stop < start
        let increment = reverse ? tickIncrement(stop, start, count) : tickIncrement(
            start,
            stop,
            count
        )
        return (reverse ? -1 : 1) * (increment < 0 ? 1 / -increment : increment)
    }

    private static func tickIncrement(_ start: Double, _ stop: Double, _ count: Double) -> Double {
        let step = (stop - start) / max(0, count)
        let power = log10(step).rounded(.down)
        let error = step / pow(10, power)
        let factor: Double = error >= 50.0.squareRoot() ? 10 : error >= 10.0.squareRoot() ? 5
            : error >= 2.0.squareRoot() ? 2 : 1
        if power < 0 { return -pow(10, -power) / factor }
        return pow(10, power) * factor
    }

    // MARK: - Intervals

    /// A d3 time interval over wall-clock milliseconds: `floor`, `offset`, and what `every` filters
    /// on.
    struct Interval {
        let floor: (Double) -> Double
        let offset: (Double, Int) -> Double
        /// d3's `field`: `every(n)` keeps the boundaries where this is a multiple of `n`.
        let field: ((Double) -> Int)?
        /// The length of every step, when they are all one length, which makes `count` a division.
        var length: Double?

        func ceil(_ time: Double) -> Double {
            floor(offset(floor(time - 1), 1))
        }

        /// d3's `every`; `nil` for a step below one.
        func every(_ step: Int) -> Interval? {
            guard step >= 1 else { return nil }
            guard step > 1 else { return self }
            let base = self
            let test: (Double) -> Bool
            if let field {
                test = { MermaidGanttTime.floorModulo(field($0), step) == 0 }
            } else {
                test = { MermaidGanttTime.floorModulo(base.count(from: 0, to: $0), step) == 0 }
            }
            return Interval(
                floor: { time in
                    var time = base.floor(time)
                    while !test(time) { time = base.floor(time - 1) }
                    return time
                },
                offset: { time, steps in
                    var time = time
                    for _ in 0..<max(0, steps) {
                        repeat { time = base.offset(time, 1) } while !test(time)
                    }
                    return time
                },
                field: nil,
                length: nil
            )
        }

        /// d3's `count`: boundaries passed from `start` to `end`.
        func count(from start: Double, to end: Double) -> Int {
            if let length { return Int(((floor(end) - floor(start)) / length).rounded()) }
            var boundary = floor(start)
            let last = floor(end)
            var count = 0
            while boundary < last {
                boundary = floor(offset(boundary, 1))
                count += 1
            }
            return count
        }

        /// d3's `range(start, stop)`: every boundary from `start` up to, not including, `stop`.
        func range(_ start: Double, _ stop: Double) -> [Double] {
            var current = ceil(start)
            var result: [Double] = []
            guard current < stop else { return result }
            var previous: Double
            repeat {
                previous = current
                result.append(current)
                current = floor(offset(current, 1))
            } while previous < current && current < stop && result.count <= maximumNamedTicks
            return result
        }
    }

    static func interval(_ unit: MermaidGanttTickInterval.Unit, weekStart: Int) -> Interval {
        switch unit {
        case .millisecond:
            return millisecondInterval(every: 1) ?? fixed(1)
        case .second: return fixed(second) { MermaidGanttTime.fields($0).second }
        case .minute: return fixed(minute) { MermaidGanttTime.fields($0).minute }
        case .hour: return fixed(hour) { MermaidGanttTime.fields($0).hour }
        case .day:
            return Interval(
                floor: MermaidGanttTime.startOfDay,
                offset: { $0 + Double($1) * day },
                field: { MermaidGanttTime.fields($0).day - 1 }
            )
        case .week:
            return Interval(
                floor: { time in
                    let midnight = MermaidGanttTime.startOfDay(time)
                    let weekday = MermaidGanttTime.fields(midnight).weekday
                    return midnight - Double((weekday + 7 - weekStart) % 7) * day
                },
                offset: { $0 + Double($1) * 7 * day },
                field: nil,
                length: 7 * day
            )
        case .month:
            return Interval(
                floor: { time in
                    let fields = MermaidGanttTime.fields(time)
                    return MermaidGanttTime.time(
                        .init(year: fields.year, month: fields.month, day: 1)
                    )
                },
                offset: { time, steps in
                    var fields = MermaidGanttTime.fields(time)
                    fields.month += steps
                    return MermaidGanttTime.time(fields)
                },
                field: { MermaidGanttTime.fields($0).month - 1 }
            )
        }
    }

    /// A unit of fixed length that starts on its own multiples, as seconds, minutes and hours do
    /// on a clock with no zone.
    private static func fixed(_ length: Double, field: ((Double) -> Int)? = nil) -> Interval {
        Interval(
            floor: { ($0 / length).rounded(.down) * length },
            offset: { $0 + Double($1) * length },
            field: field,
            length: length
        )
    }

    /// d3's `millisecond.every(k)`, which floors to multiples of `k` directly.
    private static func millisecondInterval(every step: Double) -> Interval? {
        let step = step.rounded(.down)
        guard step.isFinite, step >= 1 else { return nil }
        return fixed(step)
    }

    /// d3's `year.every(k)`, which floors to a year that is a multiple of `k`.
    private static func yearInterval(every step: Double) -> Interval? {
        let step = Int(step.rounded(.down))
        guard step >= 1 else { return nil }
        return Interval(
            floor: { time in
                let year = MermaidGanttTime.fields(time).year
                return MermaidGanttTime.time(.init(
                    year: MermaidGanttTime.floorDivide(year, step) * step,
                    month: 1,
                    day: 1
                ))
            },
            offset: { time, steps in
                var fields = MermaidGanttTime.fields(time)
                fields.year += steps * step
                return MermaidGanttTime.time(fields)
            },
            field: nil
        )
    }
}
