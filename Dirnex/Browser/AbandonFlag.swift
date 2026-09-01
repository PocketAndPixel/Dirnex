import Foundation

/// A one-way "stop" a running size walk polls, so the queue can abandon **one** of the walks in its
/// task group.
///
/// A task group cannot cancel an individual child — cancelling reaches all of them — and the walk
/// is a synchronous `DirectorySizer` loop rather than something a `Task` handle addresses. So the
/// flag is what `DirectorySizeBudget.abandonsWhenUnwatched` is expressed with: the pane stops
/// looking, the queue sets it, and `DirectorySizer` reads it at the next directory it pops.
///
/// `@unchecked Sendable` around an `NSLock` for the ordinary reason: it is written on the main
/// actor and read on the walk's own thread.
final class AbandonFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var abandoned = false

    var isAbandoned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abandoned
    }

    func abandon() {
        lock.lock()
        abandoned = true
        lock.unlock()
    }
}
