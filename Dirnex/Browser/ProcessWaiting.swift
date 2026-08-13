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

    /// Wait for `group`, giving up at `deadline` and polling `isCancelled` as it goes.
    ///
    /// The interval is a compromise with nothing subtle in it: short enough that Stop feels
    /// immediate, long enough that an hour-long transfer does not spend a thread waking up. It
    /// costs a metadata request nothing, since that finishes inside the first wait.
    ///
    /// Note the ordering — the group is checked **before** cancellation, so a process that has
    /// already finished reports `.finished` even if Stop arrived in the same instant. Answering
    /// `.cancelled` there would discard an answer that is already in hand, and for a *download*
    /// that means throwing away bytes that have already been paid for.
    static func wait(
        for group: DispatchGroup,
        deadline: DispatchTime,
        isCancelled: () -> Bool
    ) -> Outcome {
        while true {
            if group.wait(timeout: .now() + pollInterval) == .success { return .finished }
            if isCancelled() { return .cancelled }
            if DispatchTime.now() >= deadline { return .timedOut }
        }
    }

    private static let pollInterval: DispatchTimeInterval = .milliseconds(100)
}
