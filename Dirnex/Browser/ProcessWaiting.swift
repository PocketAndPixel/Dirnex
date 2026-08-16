import Foundation

/// Waiting for a spawned tool's pipes to drain, in a way a caller's Stop can interrupt
/// (PLAN.md §M21 Slice 10).
///
/// All three remote transports have the same shape — spawn one `curl` or `sftp`, drain both pipes
/// on background queues, join through a `DispatchGroup` — and all three had the same hole: the join
/// was a single bounded `wait`, so it came back only when the process was **finished**. A transfer
/// is one invocation that may run for an hour, which meant `isCancelled` could not be consulted
/// until there was nothing left to cancel.
///
/// Measured 2026-08-14 through the real `S3Backend` and the app's own transport, against a server
/// trickling 4 MiB over 16 seconds: Stop pressed at 1.00 s, `copyFile` returned at **16.98 s**, the
/// server's log read `SERVED all 4194304 bytes` — no client disconnect — and the destination held
/// the **complete** file, with a `CancellationError` thrown over the top. So the entire cost was
/// paid and the result discarded. It had been true for SFTP since M5 and FTP since M13, and nothing
/// looked wrong precisely because a *partial* download was impossible: the file that arrived was
/// always correct, and on anything small enough to test with by hand, Stop and completion are
/// indistinguishable (docs/NOTES.md ▸ curl for S3).
///
/// One home rather than three copies, because a rule spelled out at several sites is this project's
/// most repeated finding — and here the compiler would check none of them: a transport that
/// silently kept the old single `wait` would go on building, testing green, and never stopping.
enum ProcessWaiting {
    /// Why the wait ended.
    enum Outcome {
        /// Both pipes drained: the process is done and its output is complete.
        case finished
        /// The deadline passed. The caller terminates and reports a timeout.
        case timedOut
        /// The caller asked to stop. The caller terminates and throws `CancellationError`.
        case cancelled
    }

    /// Wait for `group`, giving up at `deadline`, polling `isCancelled` as it goes and calling
    /// `onPoll` on every turn.
    ///
    /// The interval is a compromise with nothing subtle in it: short enough that Stop feels
    /// immediate, long enough that an hour-long transfer does not spend a thread waking up. It
    /// costs a metadata request nothing, since that finishes inside the first wait.
    ///
    /// `onPoll` is where a transfer's *progress* is read, and it rides this loop for a reason
    /// beyond convenience: this runs on the **caller's own thread** — the operation engine's, which
    /// is parked here for the length of the transfer — so a byte count delivered from it reaches
    /// `CopyEngine`'s tally on the thread that owns it, with no second thread touching the run's
    /// state while it is blocked.
    ///
    /// Note the ordering — the group is checked **before** cancellation, so a process that has
    /// already finished reports `.finished` even if Stop arrived in the same instant. Answering
    /// `.cancelled` there would discard an answer that is already in hand, and for a *download*
    /// that means throwing away bytes that have already been paid for.
    static func wait(
        for group: DispatchGroup,
        deadline: DispatchTime,
        isCancelled: () -> Bool,
        onPoll: () -> Void = {}
    ) -> Outcome {
        while true {
            if group.wait(timeout: .now() + pollInterval) == .success { return .finished }
            onPoll()
            if isCancelled() { return .cancelled }
            if DispatchTime.now() >= deadline { return .timedOut }
        }
    }

    private static let pollInterval: DispatchTimeInterval = .milliseconds(100)

    /// Have `process`'s own termination join `group`, so waiting on the group ends when the process
    /// has been reaped. **Call it before `run()`** — a handler installed afterwards can miss a
    /// process that has already exited, and one installed on a `run()` that *threw* never fires at
    /// all, so a caller whose launch failed must not go on to wait.
    ///
    /// This exists because **`Process.waitUntilExit()` is a poll, not a wait** — measured
    /// 2026-08-16, while verifying M22's FTP walk. It costs a flat **≈71 ms** whatever the child
    /// did: `/usr/bin/true` pays the same as a full FTP listing, and a child that has been *dead
    /// for 300 ms* still costs 71.3 ms (8 runs, 70.1–72.5 — the tightness is the tell, since a
    /// timer does not vary with the work). The same reap through `terminationHandler` is 2.1 ms,
    /// and a bare `posix_spawn` + `waitpid` 1.0 ms.
    ///
    /// So the tax is fixed and its *relative* size is inversely proportional to how fast the child
    /// is, which is why it hid for so long: on `git status` (≈320 ms) it is a quarter of the cost
    /// and looks like git being slow, while on a listing it is nearly all of it. M22's walk is what
    /// made it visible, by spending one invocation **per directory** — a whole-tree FTP search over
    /// 12 directories went **1.04 s → 0.09 s** on the same server, with byte-identical hits.
    ///
    /// It is safe on the two branches that matter and both were probed rather than assumed: after
    /// `terminate()` the group still completes promptly (measured 0.51 s on a deadline of 0.5, and
    /// 0.41 s on a Stop at 0.4), and `terminationStatus` is readable in every case — it is the
    /// handler firing that says the process was reaped, which is the whole of what
    /// `waitUntilExit()` was being asked for.
    static func joinTermination(of process: Process, into group: DispatchGroup) {
        group.enter()
        process.terminationHandler = { _ in group.leave() }
    }

    /// ``joinTermination(of:into:)`` for a caller with nothing else to join — the sites that read
    /// one pipe to EOF and then reap. Set it up before `run()`, and call the returned closure where
    /// `waitUntilExit()` used to be; skip it on the path where `run()` threw.
    static func exitWaiter(for process: Process) -> () -> Void {
        let group = DispatchGroup()
        joinTermination(of: process, into: group)
        return { group.wait() }
    }
}
