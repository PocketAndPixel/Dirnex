import AppKit
import DirnexCore

/// Bridges the copy engine's synchronous, background-thread error callback
/// (`CopyEngine.run(onError:)`) to the app's main-actor per-file error dialog, and remembers
/// an "apply to all" choice for the rest of the operation (PLAN.md §M2 "Errors: per-file
/// skip/retry/abort").
///
/// One prompter is created per enqueued copy/move, so an "apply to all" tick is scoped to that
/// operation — the sibling of `ConflictPrompter` for failures rather than collisions, sharing
/// its background-parks-on-a-semaphore shape.
///
/// The engine calls `resolve(_:)` on its detached copy thread and blocks there while the sheet
/// is on screen; the main actor stays free to run the dialog.
final class ErrorPrompter: @unchecked Sendable {
    private weak var window: NSWindow?

    /// Set once the user ticks "apply to all" on a Skip; every later failure in this operation
    /// is skipped without a prompt. Only `.skip` is ever remembered — a sticky `.retry` would
    /// spin forever on a permanent error, and `.abort` ends the op outright. Touched only on
    /// the engine's single copy thread (sources are resolved serially), so it needs no lock.
    private var stickySkip = false

    init(window: NSWindow?) {
        self.window = window
    }

    /// The `@Sendable` hook handed to `CopyEngine.run(onError:)`. Called per failed source on
    /// the copy thread; blocks it until the user answers on the main actor, or returns the
    /// remembered "skip all" immediately.
    func resolve(_ context: OperationErrorContext) -> ErrorResolution {
        if stickySkip { return .skip }

        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        // The dialog must run on the main actor; `self.window` is read there, never on the
        // copy thread. The semaphore hands the answer back with a clean happens-before.
        Task { @MainActor in
            outcome.value = await ErrorDialog.present(context, in: self.window)
            semaphore.signal()
        }
        semaphore.wait()

        let (resolution, applyToAll) = outcome.value
        if applyToAll, resolution == .skip { stickySkip = true }
        return resolution
    }

    /// Shuttles the dialog's answer from the main actor back to the blocked copy thread. The
    /// semaphore establishes the ordering, so a plain `var` behind `@unchecked Sendable` is
    /// safe (written on main before `signal()`, read on the copy thread after `wait()`).
    private final class Outcome: @unchecked Sendable {
        var value: (resolution: ErrorResolution, applyToAll: Bool) = (.abort, false)
    }
}
