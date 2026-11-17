import AppKit
import DirnexCore
import IOKit.pwr_mgt
import Testing

@testable import Dirnex

/// The slideshow's rules about time and about which file (PLAN.md §M39 ▸ Slice 16), driven with a
/// real pane and a clock the test ends by hand, so nothing here waits on a timer.
@Suite("Quick View slideshow")
@MainActor
struct QuickViewSlideshowTests {
    private static let here = VFSPath.local("/tmp/dirnex-slideshow")
    /// Pictures at rows 0, 2 and 4, with a document between each pair.
    private static let names = ["1.jpg", "2.txt", "3.png", "4.md", "5.heic"]

    private func makePane(_ names: [String] = Self.names) async throws -> WindowedPane {
        let entries = names.map { Handoff.local("\(Self.here.path)/\($0)") }
        let backend = Handoff.StubBackend(listings: [Self.here: entries])
        let source = windowedPane(showing: entries, at: Self.here, backend: backend)
        try await settleUntil { source.pane.tabs[0].hasLoaded }
        source.pane.moveCursor(toDisplayedRow: 0)
        try #require(source.pane.slideshowCursorIndex == 0)
        return source
    }

    /// A slideshow on `pane` whose page turn moves the cursor straight to the row, as the window's
    /// does under its slide, and records where it went.
    private func slideshow(
        on pane: PanelViewController,
        clock: ManualClock,
        steps: StepLog,
        seconds: @escaping @MainActor () -> Int = { 5 }
    ) -> QuickViewSlideshow {
        QuickViewSlideshow(
            pane: pane,
            interval: { .seconds(seconds()) },
            schedule: clock.schedule,
            advance: { row in
                steps.rows.append(row)
                pane.moveCursor(toDisplayedRow: row)
            }
        )
    }

    @Test("the countdown waits for the picture, then runs for the interval")
    func waitsForThePicture() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        let show = slideshow(on: source.pane, clock: clock, steps: StepLog())
        defer { show.end() }

        show.surfaceDidUpdate(awaitingContent: true)
        #expect(!clock.isRunning, "a picture still decoding has not had any of its turn")
        show.surfaceDidUpdate(awaitingContent: false)
        #expect(clock.started == [.seconds(5)])
    }

    @Test("each step passes over documents to the next picture, and the last wraps to the first")
    func stepsAndWraps() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        let steps = StepLog()
        let show = slideshow(on: source.pane, clock: clock, steps: steps)
        defer { show.end() }

        for _ in 0..<3 {
            show.surfaceDidUpdate(awaitingContent: false)
            clock.finish()
        }
        #expect(steps.rows == [2, 4, 0])
        #expect(source.pane.slideshowCursorIndex == 0)
    }

    /// A background refresh or a style switch delivers the same file again; restarting on it would
    /// let a busy folder hold one picture up for ever.
    @Test("delivering the same file again leaves the countdown running")
    func sameFileKeepsItsCountdown() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        let show = slideshow(on: source.pane, clock: clock, steps: StepLog())
        defer { show.end() }

        show.surfaceDidUpdate(awaitingContent: false)
        show.surfaceDidUpdate(awaitingContent: false)
        #expect(clock.started.count == 1)
        #expect(clock.cancels == 0)
        #expect(clock.isRunning)
    }

    /// Oleg's call: a step of the user's own carries on from where it lands. A document stepped onto
    /// gets a turn too, and the show goes on to the picture after it.
    @Test("a manual step restarts the countdown from the file it lands on")
    func manualStepRestarts() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        let steps = StepLog()
        let show = slideshow(on: source.pane, clock: clock, steps: steps)
        defer { show.end() }

        show.surfaceDidUpdate(awaitingContent: false)
        source.pane.moveCursor(toDisplayedRow: 3)
        show.surfaceDidUpdate(awaitingContent: true)
        #expect(clock.cancels == 1, "the old file's countdown must not run on into the new one")
        #expect(!clock.isRunning)
        show.surfaceDidUpdate(awaitingContent: false)
        #expect(clock.started.count == 2)
        clock.finish()
        #expect(steps.rows == [4])
    }

    @Test("a lone picture counts again without turning the page")
    func lonePictureCountsAgain() async throws {
        let source = try await makePane(["1.jpg", "2.txt"])
        let clock = ManualClock()
        let steps = StepLog()
        let show = slideshow(on: source.pane, clock: clock, steps: steps)
        defer { show.end() }

        show.surfaceDidUpdate(awaitingContent: false)
        clock.finish()
        #expect(steps.rows.isEmpty)
        #expect(clock.started.count == 2)
    }

    @Test("a pane with no picture left ends the show rather than counting on")
    func runsOut() async throws {
        let source = try await makePane(["2.txt", "4.md"])
        let clock = ManualClock()
        let steps = StepLog()
        let show = slideshow(on: source.pane, clock: clock, steps: steps)
        defer { show.end() }
        var ranOut = 0
        show.onRunOut = { ranOut += 1 }

        show.surfaceDidUpdate(awaitingContent: false)
        clock.finish()
        #expect(ranOut == 1)
        #expect(steps.rows.isEmpty)
        #expect(!clock.isRunning)
    }

    @Test("the interval is read each time a countdown starts, so a new setting applies to the next")
    func intervalIsReadEachTime() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        var seconds = 5
        let show = slideshow(on: source.pane, clock: clock, steps: StepLog(), seconds: { seconds })
        defer { show.end() }

        show.surfaceDidUpdate(awaitingContent: false)
        seconds = 2
        clock.finish()
        show.surfaceDidUpdate(awaitingContent: false)
        #expect(clock.started == [.seconds(5), .seconds(2)])
    }

    @Test("the show belongs to its pane and its folder: another pane or another folder is not it")
    func belongsToItsPaneAndFolder() async throws {
        let source = try await makePane()
        let other = try await makePane()
        let show = slideshow(on: source.pane, clock: ManualClock(), steps: StepLog())
        defer { show.end() }

        #expect(show.isStill(showing: source.pane))
        #expect(!show.isStill(showing: other.pane))
        source.pane.panel = Panel(path: .local("/tmp/dirnex-slideshow-elsewhere"))
        #expect(!show.isStill(showing: source.pane))
    }

    /// The screen saver would end a slideshow nobody is touching. Read from the power manager itself,
    /// so this measures the assertion rather than our own flag.
    @Test("the display is kept awake while the show runs, and let go when it ends")
    func keepsTheDisplayAwake() async throws {
        let source = try await makePane()
        let clock = ManualClock()
        let show = slideshow(on: source.pane, clock: clock, steps: StepLog())
        #expect(show.keepsDisplayAwake)
        #expect(Self.displaySleepAssertions().contains("Quick View slideshow"))

        show.surfaceDidUpdate(awaitingContent: false)
        show.end()
        #expect(!show.keepsDisplayAwake)
        #expect(!Self.displaySleepAssertions().contains("Quick View slideshow"))
        #expect(clock.cancels == 1)
        #expect(!clock.isRunning)
    }

    /// The names of this process's assertions that hold the display awake.
    private static func displaySleepAssertions() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let mine = byProcess[NSNumber(value: getpid())]
        else { return [] }
        return mine
            .filter { $0[kIOPMAssertionTypeKey] as? String == kIOPMAssertPreventUserIdleDisplaySleep }
            .compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
}

/// Where the slideshow turned the page to, in order.
@MainActor
final class StepLog {
    var rows: [Int] = []
}

/// A countdown the test ends by hand. Records every length asked for and every cancel, and runs at
/// most one countdown at a time, as the slideshow does.
@MainActor
final class ManualClock {
    private(set) var started: [Duration] = []
    private(set) var cancels = 0
    private var running: (@MainActor () -> Void)?
    private var generation = 0

    var isRunning: Bool { running != nil }

    var schedule: QuickViewSlideshow.Scheduler {
        { [unowned self] duration, fire in
            started.append(duration)
            generation += 1
            let mine = generation
            running = fire
            return QuickViewSlideshow.Countdown { [unowned self] in
                guard generation == mine, running != nil else { return }
                cancels += 1
                running = nil
            }
        }
    }

    /// End the running countdown, as the real one does when its time is up.
    func finish() {
        let fire = running
        running = nil
        fire?()
    }
}
