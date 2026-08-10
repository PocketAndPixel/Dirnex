import Foundation

/// Runs a blocking body somewhere it is *allowed* to block, and suspends the caller — rather than
/// occupying a thread — until it finishes.
///
/// `Task.detached` is the natural-looking home for a synchronous engine and is the wrong one. A
/// detached task runs on the **cooperative pool**, whose width is the machine's active core count,
/// so a body that blocks there holds one of those workers for as long as it runs — and
/// `OperationControl.checkpoint()` holds it *indefinitely* while the queue is paused. A few
/// concurrent jobs can then occupy every cooperative thread the process has, stalling `async` work
/// that has nothing to do with moving bytes. The comment this replaced said "run it detached so the
/// actor stays responsive", which is true and is not the same claim as "on a thread of its own".
///
/// Measured rather than reasoned about: forcing the pool to a single thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`) makes `FileOperationQueue`'s scheduling tests fail with
/// a queued job that simply never starts, and that same starvation failed a release build on a CI
/// runner with far fewer cores than the developer's Mac. See docs/NOTES.md.
///
/// A global `DispatchQueue` is the right destination for exactly the property usually held against
/// it: it overcommits, growing its thread count when its threads block, which is what long
/// synchronous I/O needs and what the cooperative pool deliberately will not do.
enum BlockingWork {
    /// Run `body` off the cooperative pool, returning its result to the awaiting caller.
    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .userInitiated,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: body())
            }
        }
    }
}
