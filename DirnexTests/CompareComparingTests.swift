import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A comparison that takes a while, and the way out of one (PLAN.md §M37 Slice 3).
@Suite("Compare window — a comparison that takes a while")
@MainActor
struct CompareComparingTests: CompareComparingTesting {
    @Test("a comparison that runs for a moment says so, and offers Stop")
    func saysComparing() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(window.toolbar.comparingState == .idle)
        #expect(await comparing(window))
        #expect(!window.toolbar.stopButton.isHidden)
        #expect(!window.toolbar.comparingSpinner.isHidden)
        #expect(window.isComparing)
        held.release()
        #expect(await until { window.comparison != nil })
        #expect(window.toolbar.comparingState == .idle)
        #expect(window.toolbar.stopButton.isHidden)
        #expect(window.toolbar.comparingSpinner.isHidden)
        #expect(!window.isComparing)
    }

    @Test("the toolbar keeps its height while it says Comparing, so the panes stay put")
    func toolbarHeightHolds() throws {
        let window = try controller(held: HeldComparison())
        func height() -> CGFloat {
            window.window?.contentView?.layoutSubtreeIfNeeded()
            return window.toolbar.frame.height
        }
        let idle = height()
        window.toolbar.showComparing()
        #expect(height() == idle)
        window.toolbar.showStopped()
        #expect(height() == idle)
        window.toolbar.showFinishedComparing()
        #expect(height() == idle)
    }

    @Test("for the first moment a comparison says nothing")
    func saysNothingAtFirst() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.comparingDelay = .seconds(3600)
        window.compute(options: LineDiffOptions())
        #expect(await until { held.runs == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(window.toolbar.comparingState == .idle)
        #expect(window.toolbar.stopButton.isHidden)
        window.abandonComparing()
    }

    @Test("a comparison over at once never flashes the Stop button")
    func quickComparisonSaysNothing() async throws {
        let held = HeldComparison()
        held.release()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await until { window.comparison != nil })
        // Past the moment the toolbar would have spoken up.
        try await Task.sleep(for: CompareWindowController.usualComparingDelay * 3)
        #expect(window.toolbar.comparingState == .idle)
        #expect(window.toolbar.stopButton.isHidden)
    }

    @Test("Stop reaches the comparison, and what it would have shown never lands")
    func stopStops() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await comparing(window))
        window.stopComparing()
        #expect(!window.isComparing)
        #expect(window.toolbar.comparingState == .stopped)
        #expect(await until { held.stopsSeen == 1 })
        #expect(window.comparison == nil)
    }

    @Test("what a comparison finishes after Stop is not shown")
    func lateResultIsDropped() async throws {
        let held = HeldComparison(ignoresStop: true)
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await until { held.runs == 1 })
        window.stopComparing()
        held.release()
        #expect(await until { held.runsFinished == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.comparison == nil)
        #expect(window.toolbar.comparingState == .stopped)
    }

    @Test("Stop empties panes that were showing the comparison before it")
    func stopEmptiesThePanes() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        try window.show(CompareWindowController.prepare(
            left: window.left,
            right: window.right,
            options: LineDiffOptions(),
            coloringLimit: 0
        ))
        #expect(window.comparison != nil)
        #expect(!window.leftPane.textView.string.isEmpty)
        #expect(window.overview.rowCount > 0)
        #expect(window.currentChange != nil)
        window.compute(options: LineDiffOptions(ignoresCase: true))
        #expect(await comparing(window))
        window.stopComparing()
        #expect(window.comparison == nil)
        #expect(window.leftPane.textView.string.isEmpty)
        #expect(window.rightPane.textView.string.isEmpty)
        #expect(window.overview.rowCount == 0)
        #expect(window.band.changeRows.isEmpty)
        #expect(window.banner.isHidden)
        #expect(window.currentChange == nil)
    }

    @Test("a stopped window offers the comparison again, and runs it")
    func compareAgain() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await comparing(window))
        window.stopComparing()
        #expect(window.toolbar.stopButton.isHidden == false)
        held.release()
        window.compareAgain()
        #expect(window.isComparing)
        #expect(await until { window.comparison != nil })
        #expect(window.toolbar.comparingState == .idle)
        #expect(held.runs == 2)
    }

    @Test("the button is Stop while one runs and Compare Again once stopped")
    func buttonFollowsState() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await comparing(window))
        let stop = window.toolbar.stopButton.title
        window.toolbar.stopButton.performClick(nil)
        #expect(window.toolbar.comparingState == .stopped)
        #expect(window.toolbar.stopButton.title != stop)
        held.release()
        window.toolbar.stopButton.performClick(nil)
        #expect(await until { window.comparison != nil })
    }

    @Test("a newer comparison stops the one it replaces")
    func newerReplaces() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await until { held.runs == 1 })
        window.compute(options: LineDiffOptions(ignoresCase: true))
        #expect(await until { held.stopsSeen == 1 && held.runs == 2 })
        held.release()
        #expect(await until { window.comparison != nil })
        #expect(window.comparison?.options.ignoresCase == true)
    }

    @Test("closing the window stops the comparison")
    func closeStops() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        window.compute(options: LineDiffOptions())
        #expect(await until { held.runs == 1 })
        window.window?.close()
        #expect(await until { held.stopsSeen == 1 })
        #expect(!window.isComparing)
    }

    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 47
        ))
    }

    @Test("⌘. stops a comparison, and is left alone when there is none")
    func commandPeriod() async throws {
        let held = HeldComparison()
        let window = try controller(held: held)
        #expect(try !window.handleKey(key(".", .command)))
        window.compute(options: LineDiffOptions())
        #expect(await until { held.runs == 1 })
        #expect(try window.handleKey(key(".", .command)))
        #expect(!window.isComparing)
        #expect(window.toolbar.comparingState == .stopped)
    }

    // MARK: - Putting text in a pane

    private final class Edits: NSObject, NSTextStorageDelegate {
        var lengths: [Int] = []

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            lengths.append(textStorage.length)
        }
    }

    @Test("a pane empties itself before taking new text")
    func paneEmptiesFirst() throws {
        let pane = ComparePaneView(side: .left)
        let lines = TextLines.split("one\ntwo\n")
        let shown = ComparisonPaneText(lines: lines, rows: [0, 1])
        let document = NSAttributedString(string: shown.text)
        pane.show(shown, document: document, fills: [.same, .same], lineCount: 2)
        #expect(pane.textView.string == "one\ntwo\n")
        let edits = Edits()
        let storage = try #require(pane.textView.textStorage)
        storage.delegate = edits
        pane.show(shown, document: document, fills: [.same, .same], lineCount: 2)
        #expect(edits.lengths == [0, 8])
    }

    @Test("what a comparison prepares off the main thread is what the panes show")
    func preparedDocuments() async throws {
        let left = try source("a.txt", "same\nthe old words\n")
        let right = try source("b.txt", "same\nthe new words\n")
        let made = await BlockingWork.run {
            try? CompareWindowController.prepare(
                left: left,
                right: right,
                options: LineDiffOptions(),
                coloringLimit: 1000
            )
        }
        let prepared = try #require(made)
        #expect(prepared.leftDocument.text.string == prepared.left.text)
        #expect(prepared.rightDocument.text.string == prepared.right.text)
        #expect(prepared.leftFills == [.same, .removed])
        #expect(prepared.rightFills == [.same, .inserted])
        #expect(prepared.changeKinds == [.change])
        let start = prepared.left.rowStarts[1]
        var marked: NSRange = .init()
        let mark = prepared.leftDocument.text.attribute(
            .backgroundColor,
            at: start + 4,
            effectiveRange: &marked
        )
        #expect(mark != nil)
        #expect(marked == NSRange(location: start + 4, length: 3))
    }

    @Test("a stopped comparison does not get as far as the panes")
    func prepareStops() throws {
        let left = try source("a.txt", "one\n")
        let right = try source("b.txt", "two\n")
        #expect(throws: CancellationError.self) {
            try CompareWindowController.prepare(
                left: left,
                right: right,
                options: LineDiffOptions(),
                coloringLimit: 1000,
                isCancelled: { true }
            )
        }
    }
}
