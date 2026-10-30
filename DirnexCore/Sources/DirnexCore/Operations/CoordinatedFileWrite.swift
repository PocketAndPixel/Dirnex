import Foundation

/// A write into a file that an app may have open, made so that app is told (PLAN.md §M33 Slice 5).
///
/// An editor built on NSDocument has the file it shows registered as a file presenter, and a
/// presenter hears only of writes made through `NSFileCoordinator`. A plain write in place left
/// TextEdit showing the old text after the compare window saved, through reactivation, until its
/// own next save refused with "the file has been changed by another application". Probed
/// 2026-10-26, with TextEdit and with a presenter in a test process, the three ways of writing:
///
/// - **Uncoordinated**, as the window wrote before: a presenter heard nothing. TextEdit kept a stale
///   document, and kept an unsaved edit over the new bytes.
/// - **Coordinated with no options**: TextEdit refreshed an unedited document at once, but it
///   **discarded an unsaved edit**, from the window and from its undo, and showed the new bytes.
/// - **Coordinated for merging**, which this takes: TextEdit saved its unsaved edit into the file
///   first, then let go, then showed the new bytes. An unedited document refreshed, as before.
///
/// Merging is what keeps an editor's unsaved edit, but only if the caller looks at the file after
/// the editor has saved it. So `body` is where the caller checks the file as well as writes it: a
/// presenter's write that lands while it lets go is already in the file when `body` runs (probed:
/// `body` read it). The compare window then finds the file changed since it was read and asks,
/// rather than writing over the edit.
///
/// A presenter that never lets go would hold the write forever, which a plain write never could.
/// So the write gives up after ``patience``: `NSFileCoordinator.cancel()` from another thread ended
/// a coordination stuck on such a presenter with `NSUserCancelledError`, without running `body`
/// (probed, after 1 s).
enum CoordinatedFileWrite {
    /// How long a write waits for the apps with the file open to let go of it. TextEdit took 34 ms
    /// to save an edit and let go; a presenter that has not answered in this long is taken to be
    /// stuck rather than slow.
    static let patience: TimeInterval = 10

    /// Run `body` inside a coordinated write of the file at `path`, after every app with the file
    /// open has saved its changes and let go, and tell those apps afterwards. `body` is handed the
    /// path to write, which a presenter's move can change.
    ///
    /// `nil` when `body` never ran: no app let go within `patience`, or the coordination failed.
    /// Blocking; call it off the main thread.
    static func run<Value>(
        _ path: String,
        patience: TimeInterval = patience,
        _ body: (String) -> Value
    ) -> Value? {
        let coordinator = Coordinator()
        let giveUp = DispatchWorkItem { coordinator.cancel() }
        giveUpQueue.asyncAfter(deadline: .now() + patience, execute: giveUp)
        defer { giveUp.cancel() }
        var value: Value?
        var error: NSError?
        coordinator.coordinator.coordinate(
            writingItemAt: URL(fileURLWithPath: path),
            options: .forMerging,
            error: &error
        ) { url in
            // Once the write is under way it is not given up.
            giveUp.cancel()
            value = body(url.path)
        }
        return value
    }

    /// The watchdog's own serial queue, never a global one. GCD starts work on a global queue only
    /// while fewer threads are busy than there are CPUs, and a cooperative thread blocked in a wait
    /// still counts, so a stuck presenter held the write past its patience whenever every one of
    /// them was waiting. Probed 2026-10-28 on a 16-CPU Mac with 15 cooperative threads held: a
    /// give-up on a global queue had not run after 15 s, and one on a serial queue ran on time
    /// every run. CI's runner has three cooperative threads (docs/NOTES.md ▸ Testing).
    private static let giveUpQueue = DispatchQueue(label: "app.dirnex.coordinated-write.give-up")

    /// The coordinator, shared with the watchdog that cancels it. `cancel()` is documented as safe
    /// from any thread, and is the only call made off the coordinating one.
    private final class Coordinator: @unchecked Sendable {
        let coordinator = NSFileCoordinator(filePresenter: nil)

        func cancel() {
            coordinator.cancel()
        }
    }
}
