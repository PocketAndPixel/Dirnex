import Foundation
import Testing

@testable import DirnexCore

/// Where a gantt's rows, bars and labels go (PLAN.md §M39 ▸ Slice 15), measured with the fixed
/// advance of 7 points a character, so every number is exact.
@Suite("Mermaid gantt layout")
struct MermaidGanttLayoutTests {
    private func drawing(_ body: String, now: Date? = nil) throws -> MermaidGanttDrawing {
        let clock = MermaidGanttClock(now: now, timeZone: MermaidGanttClock.none.timeZone)
        guard case let .gantt(gantt) = MermaidParser.parse("gantt\n" + body, clock: clock) else {
            throw Missing()
        }
        return MermaidGanttLayout.lay(out: gantt, metric: .fixedAdvance)
    }

    private struct Missing: Error {}

    /// Fifty days across 700 points: 14 a day.
    private static let fiftyDays = """
        dateFormat YYYY-MM-DD
        section Section
            A task          :a1, 2014-01-01, 30d
            Another task    :after a1, 20d
        section Another
            Task in Another :2014-01-12, 12d
            another task    :24d
    """

    @Test("rows, bars and the axis, at 14 points a day")
    func rows() throws {
        let chart = try drawing(Self.fiftyDays)
        #expect(chart.bars.map(\.frame) == [
            MermaidRect(x: 75, y: 19, width: 420, height: 20),
            MermaidRect(x: 229, y: 67, width: 168, height: 20),
            MermaidRect(x: 397, y: 91, width: 336, height: 20),
            MermaidRect(x: 495, y: 43, width: 280, height: 20)
        ])
        #expect(chart.axisY == 115)
        #expect(chart.gridTop == 4)
        #expect(chart.tickLabelY == 125)
        #expect(chart.height == 135)
        #expect(chart.width == 850)
        #expect(chart.ticks.map(\.x) == [131, 229, 327, 425, 523, 621, 719])
        #expect(chart.ticks.first?.label == "2014-01-05")
        #expect(chart.ticks.allSatisfy { $0.label != nil })
    }

    @Test("a section's stripe on every other section, its name centred on its rows")
    func sections() throws {
        let chart = try drawing(Self.fiftyDays)
        #expect(chart.bands == [
            MermaidRect(x: 0, y: 17, width: 812.5, height: 24),
            MermaidRect(x: 0, y: 41, width: 812.5, height: 24)
        ])
        #expect(chart.sections.map(\.text) == ["Section", "Another"])
        #expect(chart.sections.map(\.at) == [MermaidPoint(x: 10, y: 41), MermaidPoint(x: 10, y: 89)])
    }

    @Test("a long section name widens its column; lines break at <br>")
    func sectionColumn() throws {
        let chart = try drawing("""
            section A section with a long name<br>and a second line
            A :a, 2014-01-01, 1d
        """)
        // 26 characters on the longer line: 182 points, and ten on each side.
        #expect(chart.bars.first?.frame.x == 202)
        #expect(chart.sections.map(\.text) == ["A section with a long name", "and a second line"])
        #expect(chart.sections.map(\.at.y) == [22, 36])
    }

    @Test("a name in its bar, after it, or before it when after would run off the chart")
    func labels() throws {
        let chart = try drawing("""
            dateFormat YYYY-MM-DD
            Fits :a, 2014-01-01, 30d
            A long name for a short bar :b, 2014-01-01, 1d
            A long name near the end :c, 2014-02-15, 2014-02-20
        """)
        let labels = chart.labels
        #expect(labels[0].anchor == .middle)
        #expect(labels[0].at == MermaidPoint(x: 285, y: 29))
        #expect(labels[1].anchor == .start)
        #expect(labels[1].at.x == 75 + 14 + 5)
        #expect(labels[2].anchor == .end)
        #expect(labels[2].at.x == 75 + 630 - 5)
    }

    @Test("a label past the left edge moves the drawing right; one past the right widens it")
    func widening() throws {
        let name = String(repeating: "x", count: 110)
        let left = try drawing("""
            A :a, 2014-01-01, 2014-01-02
            \(name) :b, 2014-01-01, 2014-01-03
        """)
        // 770 points of name ending 5 points before the bar at 75 start 700 points left of zero.
        #expect(left.labels[1].anchor == .end)
        #expect(left.labels[1].at.x - 770 == 4)
        #expect(left.bars.map(\.frame.x) == [779, 779])
        #expect(left.width == 850 + 704)

        let right = try drawing("""
            A :a, 2014-01-01, 2014-01-10
            The deadline, written long :vert, v, 2014-01-10, 0d
        """)
        // 26 characters, 182 points, centred on the chart's end at 775.
        #expect(right.width == 775 + 91 + 4)
        #expect(right.bars.first?.frame.x == 75)
    }

    @Test("a name that does not fit goes after its bar while it stays within the right margin")
    func afterTheBar() throws {
        let chart = try drawing("""
            A :a, 2014-01-01, 2014-01-10
            Short bar, rather long name :b, 2014-01-09, 2014-01-10
            Short bar, longish :c, 2014-01-07, 2014-01-08
        """)
        // 622 + 189 runs more than half the margin past 700; 544 + 126 does not.
        #expect(chart.labels.map(\.anchor) == [.middle, .start, .end])
        #expect(
            chart.labels.map(\.text) == ["A", "Short bar, longish", "Short bar, rather long name"]
        )
        #expect(chart.width == 850)
    }

    @Test("a milestone is a diamond at the middle of its start and end")
    func milestone() throws {
        let chart = try drawing("""
            A :a, 2014-01-01, 2014-01-11
            Done :milestone, m, 2014-01-05, 2d
        """)
        let diamond = try #require(chart.bars.last)
        #expect(diamond.isMilestone)
        #expect(diamond.frame.midX == 75 + 350)
        #expect(diamond.frame.midY == 53)
        #expect(abs(diamond.frame.width - 22.627) < 0.001)
        // Measured as a 20-point bar: "Done" does not fit, so it goes after.
        #expect(chart.labels.last?.at.x == 440.0) // 75 + 350 + 10 + 5
        #expect(chart.labels.last?.isMilestone == true)
    }

    @Test("a vert marker takes no row, draws across the chart and writes its name under it")
    func verticalMarker() throws {
        let chart = try drawing("""
            A :a, 2014-01-01, 2014-01-11
            Deadline :vert, v, 2014-01-06, 0d
            B :b, 2014-01-02, 1d
        """)
        #expect(chart.bars.count == 2)
        #expect(chart.axisY == 19 + 48)
        #expect(chart.markers.map(\.x) == [75 + 350])
        #expect(chart.markers.first?.label.at.y == 93.0) // 67 + 26
        #expect(chart.height == 67 + 16 + 4 + 16)
    }

    @Test("the today line, only when today is on the chart")
    func today() throws {
        let inside = try drawing(
            "A :a, 2014-01-01, 2014-01-11",
            now: Date(timeIntervalSince1970: 1_388_966_400)
        )
        #expect(inside.today == 425.0) // 75 + 350
        let outside = try drawing(
            "A :a, 2014-01-01, 2014-01-11",
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(outside.today == nil)
    }

    @Test("topAxis writes the dates over the chart too, and moves the rows down for them")
    func topAxis() throws {
        let chart = try drawing("topAxis\nA :a, 2014-01-01, 2014-01-11")
        #expect(chart.gridTop == 20)
        #expect(chart.topTickLabelY == 12)
        #expect(chart.bars.first?.frame.y == 35)
    }

    @Test("excluded days shade the chart from the grid's top to the axis")
    func excluded() throws {
        let chart = try drawing("excludes weekends\nA :a, 2014-01-06, 2014-01-16")
        #expect(chart.excluded == [MermaidRect(x: 75 + 350, y: 4, width: 140, height: 39)])
    }

    @Test("a bar stops before the excluded days its end was pushed over")
    func drawnEnd() throws {
        // Thursday to Monday is 175 points a day; the bar draws Thursday and Friday.
        let chart = try drawing("excludes weekends\nA :a, 2014-01-09, 2d")
        #expect(chart.bars.first?.frame.width == 350.0)
    }

    @Test("tick labels that would touch are thinned to every other, and the grid keeps every line")
    func thinning() throws {
        // 22 days, a tick every other day: 63.6 points apart for labels 63.6 points wide.
        let chart = try drawing("A :a, 2014-01-06, 2014-01-28")
        #expect(chart.ticks.count == 11)
        #expect(chart.ticks.map { $0.label != nil } == (0..<11).map { $0 % 2 == 0 })
        #expect(chart.ticks.first?.label == "2014-01-07")
    }

    @Test("bars are painted by start; an unplaced task keeps its row with no bar")
    func paintOrderAndGaps() throws {
        let chart = try drawing("""
            Later :a, 2014-01-05, 1d
            Earlier :b, 2014-01-01, 1d
            Lost :c, after nobody, 1d
            Last :d, 2014-01-02, 1d
        """)
        #expect(chart.labels.map(\.text) == ["Earlier", "Last", "Later"])
        #expect(chart.bars.map(\.frame.y) == [43, 91, 19])
        #expect(chart.axisY == 19 + 96)
    }

    @Test("a section written again further down is a block of its own, in its first stripe")
    func repeatedSection() {
        func task(_ section: String, _ row: Int) -> MermaidGantt.Task {
            MermaidGantt.Task(
                name: "t", id: "t\(row)", section: section, row: row, start: 0, end: 1,
                drawnEnd: nil,
                isActive: false, isDone: false, isCritical: false, isMilestone: false,
                isVertical: false
            )
        }
        let blocks = MermaidGanttLayout.sectionBlocks(
            [task("A", 0), task("B", 1), task("A", 2), task("A", 3)]
        )
        #expect(blocks == [
            .init(name: "A", firstRow: 0, rows: 1, style: 0),
            .init(name: "B", firstRow: 1, rows: 1, style: 1),
            .init(name: "A", firstRow: 2, rows: 2, style: 0)
        ])
    }

    @Test("a chart of one instant draws at its middle, as d3's scale does")
    func instant() throws {
        let chart = try drawing("Now :milestone, m, 2014-01-01, 0d")
        #expect(chart.bars.first?.frame.midX == 425.0) // 75 + 350
        #expect(chart.ticks.map(\.x) == [75 + 350])
    }
}
