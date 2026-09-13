import Foundation
import Testing

@testable import Dirnex

/// What a pane on the Photos library waits on (PLAN.md §M28 Slice 4): a count of the library's
/// changes, and a stream that wakes when the count moves.
///
/// Each test drives a monitor of its own and never ``PhotosLibraryChangeMonitor/startIfPermitted()``,
/// which is the one call that touches PhotoKit — so nothing here registers with the library or could
/// raise a privacy prompt in a test host.
@MainActor
@Suite("Photos library change monitor")
struct PhotosLibraryChangeMonitorTests {
    @Test("a change counts once and wakes a pane that is waiting for it")
    func changeWakesAWaiter() async {
        let monitor = PhotosLibraryChangeMonitor()
        var changes = monitor.changes().makeAsyncIterator()

        monitor.noteLibraryChanged()

        #expect(monitor.generation == 1)
        #expect(await changes.next() == 1)
    }

    /// A waiter re-reads the generation when it wakes, so a burst must cost it one wake rather than
    /// a queue of them — which is what keeps one gesture in Photos to one refresh.
    @Test("a burst of changes leaves only the newest waiting")
    func burstBuffersTheNewest() async {
        let monitor = PhotosLibraryChangeMonitor()
        var changes = monitor.changes().makeAsyncIterator()

        monitor.noteLibraryChanged()
        monitor.noteLibraryChanged()
        monitor.noteLibraryChanged()

        #expect(await changes.next() == 3)
        #expect(monitor.generation == 3)
    }

    /// The narrowness half of the count: a stream taken after a change must not replay it, or a
    /// pane arriving on the library would refresh straight after the listing that brought it there.
    @Test("a stream taken after a change does not hear it")
    func noReplay() async {
        let monitor = PhotosLibraryChangeMonitor()
        monitor.noteLibraryChanged()
        var changes = monitor.changes().makeAsyncIterator()

        monitor.noteLibraryChanged()

        #expect(await changes.next() == 2)
    }

    /// How a pane stops waiting: its loop's task is cancelled when it stands down or navigates away.
    /// A wait that ignored cancellation would hang the loop's task forever and keep its subscription.
    @Test("a cancelled wait ends, and its subscription is forgotten")
    func cancelledWaitEnds() async throws {
        let monitor = PhotosLibraryChangeMonitor()
        let stream = monitor.changes()
        #expect(monitor.subscriberCount == 1)

        let waiter = Task { @MainActor in
            var changes = stream.makeAsyncIterator()
            return await changes.next()
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        #expect(await waiter.value == nil)
        // The subscription is dropped by a hop back to the main actor, which a full run can hold for
        // seconds at a time (docs/NOTES.md ▸ Testing), so the wait is the house budget rather than a
        // guess at how late that hop can be.
        let deadline = Date().addingTimeInterval(30)
        while monitor.subscriberCount > 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(monitor.subscriberCount == 0)
    }
}
