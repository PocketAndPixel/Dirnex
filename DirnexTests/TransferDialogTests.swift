import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The copy and move dialog (PLAN.md §M41): Return, Return starts a copy and sends it to the queue
/// bar; Escape on the question copies nothing; Escape, Return on the progress stops it.
///
/// The dialog is driven in a plain window rather than as a sheet, and the keys go through
/// `performKeyEquivalent`, the entry `NSWindow.sendEvent` uses for a key down. Computer use cannot
/// send Escape into the app at all (docs/LIVE-VERIFICATION.md), so this is where Escape is pinned.
/// The Stop question is an `NSAlert`, and presenting one inside the test host kills it
/// (docs/NOTES.md ▸ The keyboard in a dialog), so its keys are read off the alert unpresented.
@MainActor
@Suite("Copy dialog", .serialized)
struct TransferDialogTests {
    // MARK: - Keys

    @Test("Return on the question starts the transfer, and Return again sends it to the background")
    func returnReturn() throws {
        let fixture = DialogFixture()
        try fixture.press("\r", code: 36)
        #expect(fixture.starts == 1)
        #expect(fixture.dialog.controller.phase == .progress)
        #expect(!fixture.dialog.isClosed)

        try fixture.press("\r", code: 36)
        #expect(fixture.dialog.isClosed)
        #expect(fixture.queue.cancelled.isEmpty, "Background leaves the jobs running")
        #expect(fixture.queue.paused.isEmpty)
    }

    @Test("Escape on the question closes it and copies nothing")
    func escapeOnQuestion() throws {
        let fixture = DialogFixture()
        try fixture.press("\u{1b}", code: 53)
        #expect(fixture.dialog.isClosed)
        #expect(fixture.starts == 0)
    }

    /// Escape on the progress reaches Cancel, which asks before stopping. What Cancel then does needs
    /// the alert on screen, which the test host cannot survive, so this pins only where the key goes.
    @Test("Escape on the progress reaches Cancel")
    func escapeOnProgress() throws {
        let fixture = DialogFixture()
        try fixture.press("\r", code: 36)
        var cancelled = false
        fixture.dialog.controller.onCancel = { cancelled = true }
        try fixture.press("\u{1b}", code: 53)
        #expect(cancelled)
        #expect(!fixture.dialog.isClosed)
    }

    /// Copy can be rebound to a ⌃, ⌥ or ⌘ chord in Settings ▸ Shortcuts, and the question is up while
    /// that modifier is still down; AppKit refuses a key equivalent whose modifiers differ. The control
    /// is the same press on a dialog built with nothing held: refused.
    @Test(
        "a key still carrying the chord that raised the question answers it",
        arguments: [true, false]
    )
    func staleChord(raisedByChord: Bool) throws {
        let (controller, window) = Self.bare(held: raisedByChord ? [.control] : [])
        var confirmed = false
        var cancelled = false
        controller.onConfirm = { _ in confirmed = true }
        controller.onCancel = { cancelled = true }

        let chordReturn = try DialogFixture.key("\r", code: 36, .control, in: window)
        let chordEscape = try DialogFixture.key("\u{1b}", code: 53, .control, in: window)
        #expect(window.performKeyEquivalent(with: chordReturn) == raisedByChord)
        #expect(window.performKeyEquivalent(with: chordEscape) == raisedByChord)
        #expect(confirmed == raisedByChord)
        #expect(cancelled == raisedByChord)
    }

    /// Measured 2026-11-17 by the control above: a plain button's Return and Escape answer with Shift
    /// held, so ⇧F5 needs none of the catcher's help. Pinned so the next reader does not add some.
    @Test("Shift on Return or Escape is answered by the buttons themselves")
    func shiftNeedsNoHelp() throws {
        let (controller, window) = Self.bare(held: [])
        var confirmed = false
        controller.onConfirm = { _ in confirmed = true }
        #expect(
            window.performKeyEquivalent(
                with: try DialogFixture.key("\r", code: 36, .shift, in: window)
            )
        )
        #expect(confirmed)
    }

    /// The question in a window, wired to nothing.
    private static func bare(held: NSEvent.ModifierFlags) -> (TransferDialogController, NSWindow) {
        let controller = TransferDialogController(
            summary: DialogFixture.summary,
            heldModifiers: held
        )
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        return (controller, window)
    }

    @Test(
        "Stop answers Return and Continue answers Escape",
        arguments: [FileOperation.Kind.copy, .move]
    )
    func stopQuestionKeys(kind: FileOperation.Kind) {
        let alert = TransferDialog.stopQuestion(kind: kind)
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons[0].keyEquivalent == "\r", "Stop")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}", "Continue")
    }

    // MARK: - The box, the hold, Pause

    @Test("Don’t ask again turns the setting off and starts this copy without the dialog")
    func dontAskAgain() throws {
        let fixture = DialogFixture()
        #expect(fixture.preferences.confirmTransfers, "on by default")
        fixture.dialog.controller.dontAskCheckbox.state = .on
        try fixture.press("\r", code: 36)
        #expect(!fixture.preferences.confirmTransfers)
        #expect(fixture.starts == 1)
        #expect(fixture.dialog.isClosed)
        #expect(fixture.dialog.controller.phase == .asking, "no progress was shown")
    }

    /// A clone is done in the turn it starts. Without the hold, the second of two quick Returns would
    /// land on the file list and open whatever is under the cursor.
    @Test("a transfer that ends at once leaves the dialog up for a second")
    func holdsForASecond() async throws {
        let fixture = DialogFixture()
        let opened = ProcessInfo.processInfo.systemUptime
        try fixture.press("\r", code: 36)
        let id = try #require(fixture.ids.first)
        fixture.dialog.handle(DialogFixture.snapshot([fixture.job(id, .finished)]))
        #expect(fixture.dialog.state.phase == .done)
        #expect(!fixture.dialog.isClosed)

        for _ in 0..<300 where !fixture.dialog.isClosed {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.dialog.isClosed)
        #expect(ProcessInfo.processInfo.systemUptime - opened >= TransferDialog.minimumShown - 0.05)
    }

    @Test("Pause pauses the transfer's own jobs, and then reads Resume and resumes them")
    func pauseAndResume() throws {
        let fixture = DialogFixture()
        try fixture.press("\r", code: 36)
        let id = try #require(fixture.ids.first)
        fixture.dialog.handle(DialogFixture.snapshot([fixture.job(id, .running)]))

        fixture.dialog.controller.pauseButton.performClick(nil)
        #expect(fixture.queue.paused == [id])

        fixture.dialog.handle(DialogFixture.snapshot([fixture.job(id, .paused, held: true)]))
        #expect(fixture.dialog.controller.pauseButton.title == String(
            localized: "Resume",
            comment: "Queue-bar button that resumes paused file operations."
        ))
        fixture.dialog.controller.pauseButton.performClick(nil)
        #expect(fixture.queue.resumed == [id])
    }

    /// An indeterminate bar that is ever started keeps sweeping after it turns determinate, for as
    /// long as its value keeps changing, which is the whole of a transfer (measured 2026-11-17 on
    /// the layer's `overallIndeterminateAnimation`). So no phase may start one.
    @Test("neither bar is ever indeterminate, from Preparing through the end")
    func barsStayDeterminate() throws {
        let fixture = DialogFixture()
        try fixture.press("\r", code: 36)
        let id = try #require(fixture.ids.first)
        let controller = fixture.dialog.controller
        let bars = [controller.fileBar, controller.totalBar]
        #expect(bars.allSatisfy { !$0.isIndeterminate }, "preparing")
        for status in [JobStatus.waiting, .running, .paused, .finished] {
            fixture.dialog.handle(DialogFixture.snapshot([fixture.job(id, status)]))
            #expect(bars.allSatisfy { !$0.isIndeterminate }, "\(status)")
        }
    }

    /// With one file the file's bar and the job's draw the same fraction, so only the job's shows.
    @Test("one file going shows one bar; a folder or several files show the file's bar as well")
    func oneFileOneBar() {
        let file = DialogFixture.summary.sources[0]
        let other = DialogFixture.entry("b.txt", kind: .file)
        let folder = DialogFixture.entry("photos", kind: .directory)
        func shows(_ sources: [FileEntry], files: Int) -> Bool {
            let controller = TransferDialogController(summary: TransferSummary(
                kind: .copy,
                sources: sources,
                destination: .local("/dest")
            ))
            _ = controller.view
            controller.showProgress()
            var state = TransferDialogState(phase: files == 0 ? .preparing : .running)
            state.totalFiles = files
            controller.render(state, detail: nil)
            return !controller.fileBar.isHidden
        }
        #expect(!shows([file], files: 0), "a lone file, before the pre-scan has counted it")
        #expect(!shows([file], files: 1))
        #expect(shows([folder], files: 0), "a folder may hold many until it is counted")
        #expect(!shows([folder], files: 1), "a folder holding one file")
        #expect(shows([folder], files: 340))
        #expect(shows([file, other], files: 0))
        #expect(shows([file, other], files: 2))
    }

    @Test("the readout counts files only when there is more than one")
    func readoutCountsSeveral() {
        var one = TransferDialogState(phase: .running, totalBytes: 10, completedBytes: 4)
        one.totalFiles = 1
        var several = one
        several.totalFiles = 2
        let oneText = TransferDialogText.detail(one, bytesPerSecond: 0, estimatedTimeRemaining: nil)
        let severalText = TransferDialogText.detail(
            several,
            bytesPerSecond: 0,
            estimatedTimeRemaining: nil
        )
        #expect(
            severalText.hasPrefix(oneText) && severalText.count > oneText.count,
            "\(severalText)"
        )
    }

    // MARK: - The rest of the app

    /// A job paused in its dialog is invisible to the queue-wide flag, which is what the bar read.
    @Test(
        "the queue bar reads a job paused in its dialog as paused, and names a running one over it"
    )
    func queueBarReadsHeldJobs() {
        let held = TransferDialogStateTests.job(
            .paused,
            current: .init(.local("/a/held.bin")),
            held: true
        )
        let running = TransferDialogStateTests.job(
            .running,
            current: .init(.local("/a/running.bin"))
        )
        #expect(QueueBarView.readsPaused(DialogFixture.snapshot([held])))
        #expect(!QueueBarView.readsPaused(DialogFixture.snapshot([held, running])))

        let bar = QueueBarView(frame: NSRect(x: 0, y: 0, width: 600, height: 42))
        let text = bar.statusText(for: DialogFixture.snapshot([held, running]))
        #expect(text.contains("running.bin"), "\(text)")
        #expect(!text.contains("held.bin"), "\(text)")
    }

    @Test("automation is flagged while it runs, and nesting restores the outer state")
    func automationFlag() {
        #expect(!Scripting.isAutomating)
        let inner = Scripting.automating {
            Scripting.automating { Scripting.isAutomating } && Scripting.isAutomating
        }
        #expect(inner)
        #expect(!Scripting.isAutomating)
    }
}

// MARK: - DialogFixture

@MainActor
final class DialogFixture {
    static let summary = TransferSummary(
        kind: .copy,
        sources: [entry("a.txt", kind: .file)],
        destination: .local("/dest")
    )

    static func entry(_ name: String, kind: FileEntry.Kind) -> FileEntry {
        FileEntry(
            path: .local("/src/\(name)"),
            name: name,
            kind: kind,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    let queue = QueueRecorder()
    let preferences = AppPreferences(defaults: ScratchDefaults.fresh())
    let dialog: TransferDialog
    let window: NSWindow
    private(set) var starts = 0
    private(set) var ids: [OperationJobID] = []
    /// The folder each start was handed.
    private(set) var destinations: [VFSPath] = []

    init(summary: TransferSummary = DialogFixture.summary) {
        dialog = TransferDialog(
            summary: summary,
            control: queue.control,
            preferences: preferences,
            onClose: {}
        )
        window = NSWindow(contentViewController: dialog.controller)
        window.isReleasedWhenClosed = false
        dialog.wire { [unowned self] tracker, destination in
            starts += 1
            destinations.append(destination)
            ids.append(tracker.nextID())
            tracker.finish()
        }
    }

    func press(_ characters: String, code: UInt16) throws {
        let event = try Self.key(characters, code: code, in: window)
        #expect(window.performKeyEquivalent(with: event), "nothing took \(code)")
    }

    func job(_ id: OperationJobID, _ status: JobStatus, held: Bool = false) -> JobSnapshot {
        JobSnapshot(id: id, kind: .copy, status: status, progress: nil, report: nil, isHeld: held)
    }

    static func snapshot(_ jobs: [JobSnapshot], paused: Bool = false) -> QueueSnapshot {
        QueueSnapshot(
            jobs: jobs,
            aggregate: AggregateProgress(
                totalJobs: jobs.count,
                finishedJobs: 0,
                activeJobs: 0,
                totalBytes: 0,
                completedBytes: 0,
                bytesPerSecond: 0,
                estimatedTimeRemaining: nil
            ),
            isPaused: paused
        )
    }

    static func key(
        _ characters: String,
        code: UInt16,
        _ modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }
}

/// What the dialog asked of the queue.
@MainActor
final class QueueRecorder {
    private(set) var paused: [OperationJobID] = []
    private(set) var resumed: [OperationJobID] = []
    private(set) var cancelled: [OperationJobID] = []

    var control: TransferDialog.QueueControl {
        TransferDialog.QueueControl(
            pause: { [unowned self] in paused.append($0) },
            resume: { [unowned self] in resumed.append($0) },
            cancel: { [unowned self] in cancelled.append($0) }
        )
    }
}
