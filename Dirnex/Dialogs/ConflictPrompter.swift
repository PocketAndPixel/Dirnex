import AppKit
import DirnexCore

/// Bridges the copy engine's synchronous, background-thread conflict callback
/// (`ConflictPolicy.ask`) to the app's main-actor rich conflict dialog, and remembers an
/// "apply to all" choice for the rest of the operation (PLAN.md §M2 "Conflict engine").
///
/// One prompter is created per enqueued copy/move, so an "apply to all" tick is scoped to
/// that operation — matching Total Commander, where "Overwrite all" governs the current
/// transfer, not the whole session.
///
/// The engine calls `resolve(_:)` on its detached copy thread and blocks there while the
/// sheet is on screen; the main actor stays free to run the dialog. This is the same
/// background-parks-on-a-primitive pattern the queue already uses for pause
/// (`JobControl.checkpoint`), so blocking the copy thread here is an established shape.
final class ConflictPrompter: @unchecked Sendable {
    private weak var window: NSWindow?

    /// Set once the user ticks "apply to all"; every later conflict in this operation takes
    /// it without a prompt. Touched only on the engine's single copy thread (the engine
    /// resolves top-level sources serially), so it needs no lock.
    private var sticky: ConflictResolution?

    init(window: NSWindow?) {
        self.window = window
    }

    /// The `@Sendable` hook handed to `CopyEngine.run(resolveConflict:)`. Called per colliding
    /// item on the copy thread; blocks it until the user answers on the main actor, or returns
    /// the remembered "apply to all" choice immediately.
    func resolve(_ context: ConflictContext) -> ConflictResolution {
        if let sticky { return sticky }

        let outcome = Outcome()
        let semaphore = DispatchSemaphore(value: 0)
        // The dialog must run on the main actor; `self.window` is read there, never on the
        // copy thread. The semaphore hands the answer back with a clean happens-before.
        Task { @MainActor in
            outcome.value = await ConflictDialog.present(context, in: self.window)
            semaphore.signal()
        }
        semaphore.wait()

        let (resolution, applyToAll) = outcome.value
        if applyToAll, resolution != .cancel { sticky = resolution }
        return resolution
    }

    /// Shuttles the dialog's answer from the main actor back to the blocked copy thread. The
    /// semaphore establishes the ordering, so a plain `var` behind `@unchecked Sendable` is
    /// safe (written on main before `signal()`, read on the copy thread after `wait()`).
    private final class Outcome: @unchecked Sendable {
        var value: (resolution: ConflictResolution, applyToAll: Bool) = (.cancel, false)
    }
}
