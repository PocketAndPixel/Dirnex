import Testing

@testable import DirnexCore

/// What the ⇧-keys do over a movie or a sound in Quick View (PLAN.md §M42 ▸ Slice 1), and the ⌘P
/// command that plays and pauses one.
@Suite("Quick View timeline")
struct QuickViewTimelineTests {
    @Test(
        "a line step is ten seconds and a page step a minute, each the way it goes down a document"
    )
    func steps() {
        #expect(QuickViewScroll.lineDown.timelineTarget(from: 30, duration: 600) == 40)
        #expect(QuickViewScroll.lineUp.timelineTarget(from: 30, duration: 600) == 20)
        #expect(QuickViewScroll.pageDown.timelineTarget(from: 30, duration: 600) == 90)
        #expect(QuickViewScroll.pageUp.timelineTarget(from: 90, duration: 600) == 30)
    }

    @Test("⇧← and ⇧→ go to the start and the end")
    func ends() {
        #expect(QuickViewScroll.top.timelineTarget(from: 312.5, duration: 600) == 0)
        #expect(QuickViewScroll.end.timelineTarget(from: 312.5, duration: 600) == 600)
    }

    @Test("a step past either end stops at it")
    func clamped() {
        #expect(QuickViewScroll.lineUp.timelineTarget(from: 4, duration: 600) == 0)
        #expect(QuickViewScroll.pageUp.timelineTarget(from: 59.9, duration: 600) == 0)
        #expect(QuickViewScroll.lineDown.timelineTarget(from: 595, duration: 600) == 600)
        #expect(QuickViewScroll.pageDown.timelineTarget(from: 600, duration: 600) == 600)
        // Shorter than one step: every move forward lands on the end.
        #expect(QuickViewScroll.lineDown.timelineTarget(from: 0, duration: 3.2) == 3.2)
    }

    /// The negative control for the clamp above: with no length to hold to, a step forward goes the
    /// whole way it asks, and only the start still holds.
    @Test("with no length known, the end stays put and only the start holds")
    func unknownLength() {
        for duration in [nil, Double.nan, .infinity, 0, -1] as [Double?] {
            #expect(QuickViewScroll.end.timelineTarget(from: 42, duration: duration) == 42)
            #expect(QuickViewScroll.pageDown.timelineTarget(from: 42, duration: duration) == 102)
            #expect(QuickViewScroll.pageUp.timelineTarget(from: 42, duration: duration) == 0)
            #expect(QuickViewScroll.top.timelineTarget(from: 42, duration: duration) == 0)
        }
    }

    @Test("a position the player cannot report yet counts as the start")
    func unknownPosition() {
        #expect(QuickViewScroll.lineDown.timelineTarget(from: .nan, duration: 600) == 10)
        #expect(QuickViewScroll.end.timelineTarget(from: .nan, duration: 600) == 600)
        #expect(QuickViewScroll.lineUp.timelineTarget(from: -5, duration: 600) == 0)
    }

    // MARK: - The command

    @Test("Play/Pause is a conflict-free View command on ⌘P")
    func command() {
        let command = CommandCatalog.all.first { $0.id == "view.quickViewPlayPause" }
        #expect(command?.category == .view)
        #expect(command?.shortcut == CommandShortcut(key: "p", modifiers: .command))
        #expect(KeyBindings().conflicts(for: "view.quickViewPlayPause").isEmpty)
    }
}
