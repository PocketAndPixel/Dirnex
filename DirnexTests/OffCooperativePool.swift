import DirnexCore
import Foundation

/// Run a blocking body somewhere it is allowed to block, and suspend the test until it finishes.
///
/// A live test drives the real transports, whose verbs are **synchronous and block** on a `curl` or
/// `sftp` subprocess for the length of a real network round trip. Written the obvious way — a
/// synchronous `@Test func` calling them directly — that blocking happens on whatever ran the test
/// body, and neither candidate can afford it:
///
/// - **The cooperative pool**, whose width is the machine's active core count. This is
///   ``BlockingWork``'s own subject, one layer out: a body that blocks there holds a worker for the
///   whole transfer, and six live suites run at once, so between them they can empty the pool and
///   starve every *other* suite's `await` — including the timing waits headless suites are built
///   from.
/// - **The main actor**, for a `@MainActor` suite, which is worse: there is only one, and most of
///   this project's headless suites are main-actor-isolated because they drive AppKit. A blocking
///   bucket verb there stops every other main-actor test from being resumed at all, for seconds.
///
/// Measured 2026-08-20 under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which narrows the pool to one
/// thread and turns the resulting flake into something reproducible: the whole app suite was **16 s
/// and green** with the live suites skipped and **86 s with 5 failures** with them in, and not one
/// of the failures was in a live test — they were in `RemoteFetchPromptTests`,
/// `RemotePreviewFetchTests` and `PanelTreeBucketExpansionTests`, whose bounded waits had simply
/// expired. That is the same class docs/NOTES.md records for `FileOperationQueue`, arriving in test
/// code rather than in the product, where the compiler cannot see it either: Swift 6 refuses
/// `Thread.sleep` directly inside an `async` function, and a *synchronous* function that blocks
/// compiles in silence.
///
/// `RemoteFileEditLiveIntegrationTests` already did this by hand at every call site; this is that
/// habit named, so the other live suites cannot each invent their own spelling.
///
/// Wrap the **whole** body rather than each call where the test measures durations — the clock, the
/// subprocess and its progress callbacks then all stay on the one thread that ran it, which is what
/// keeps a timing assertion measuring the transfer instead of the scheduler.
func offCooperativePool<T: Sendable>(
    _ body: @escaping @Sendable () throws -> T
) async throws -> T {
    try await BlockingWork.run { Result(catching: body) }.get()
}
