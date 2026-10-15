import AppKit
import Foundation
import Testing

@testable import Dirnex

/// Resting the pointer on a truncated value floats it (`HoverExpansion`).
///
/// The wait and the pointer itself are a monitor and timers, which a headless test cannot move. What
/// it can reach is the question every one of them asks: which value, if any, is under a point.
@Suite("Hover expansion")
@MainActor
struct HoverExpansionTests {
    static let longName = ExpansionTableFixture.longName

    @Test("the pointer on a truncated name finds its label")
    func truncatedNameIsFound() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, "a.txt"])
        let label = try #require(fixture.label(atRow: 0))

        let found = HoverExpansion.truncatedLabel(
            at: fixture.screenPoint(atMiddleOf: label),
            in: fixture.window
        )
        #expect(found === label)
    }

    @Test("a name that fits, the icon beside a name, and the empty rows find nothing")
    func nothingElseIsFound() throws {
        let fixture = ExpansionTableFixture(names: [Self.longName, "a.txt"])
        let short = try #require(fixture.label(atRow: 1))
        #expect(HoverExpansion.truncatedLabel(
            at: fixture.screenPoint(atMiddleOf: short),
            in: fixture.window
        ) == nil)

        let long = try #require(fixture.label(atRow: 0))
        let cell = try #require(long.superview)
        let besideName = NSPoint(x: cell.bounds.minX + 2, y: cell.bounds.midY)
        let onIcon = fixture.window.convertPoint(toScreen: cell.convert(besideName, to: nil))
        #expect(HoverExpansion.truncatedLabel(at: onIcon, in: fixture.window) == nil)

        let belowRows = fixture.window.convertPoint(toScreen: NSPoint(x: 100, y: 10))
        #expect(HoverExpansion.truncatedLabel(at: belowRows, in: fixture.window) == nil)
    }
}
