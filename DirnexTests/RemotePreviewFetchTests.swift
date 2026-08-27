import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The fetch nobody pressed a key for: Quick View following the cursor onto a file on a server
/// (PLAN.md §M21 Slice 10).
///
/// This is what makes the mode work at all on a server, and what keeps it defensible is that it
/// is **bounded three ways** — a *sweep* costs nothing (the settle delay), a large object is
/// declined rather than asked about (`RemoteFetchPolicy`, pinned in the core), and leaving the
/// row abandons the transfer. Take a bound away and this is a billed request per row the cursor
/// passed over, which is the rule the whole slice was built around.
///
/// Every wait here is an `await`, never a run-loop spin: what is being waited for is a detached
/// transfer’s continuation, and a spin never suspends the main actor (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("Remote preview fetch")
struct RemotePreviewFetchTests {
    /// The bound that makes the whole thing affordable: travelling through a folder must cost
    /// nothing. Five rows scheduled back to back is what a held arrow key looks like from here —
    /// each supersedes the last inside the settle delay, so only where the cursor *stopped* is ever
    /// requested. Without the delay this is five transfers, which is the arrow-key spend the
    /// original no-passive-path rule was written against.
    ///
    /// The rows are stepped **with real gaps between them**, and that is the whole design of the
    /// test: scheduled back to back in one synchronous loop they would supersede each other before
    /// any of their tasks had run at all, so the assertion would pass with no settle delay
    /// whatsoever — a test that agrees with the bug. 50 ms apart is roughly a held arrow key, and
    /// the main actor suspends in between, which is what gives a delay-less scheduler its chance to
    /// spend five requests.
    @Test("sweeping the cursor across five rows transfers only the one it came to rest on")
    func aSweepTransfersOnlyTheRowItStopsOn() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let names = ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]

        for name in names {
            cache.scheduleAutomaticFetch(Fixture.entry(name), using: backend, onSettled: {})
            try? await Task.sleep(for: .milliseconds(50))
        }
        // On the *cache*, not on `copyCount`: the counter is bumped as the transfer starts, so
        // waiting on it can return before the copy has been recorded — which fails as "the row it
        // stopped on was not fetched", i.e. as the feature being broken rather than as the wait.
        await settle { cache.cachedURL(for: Fixture.entry("e.txt")) != nil }

        #expect(backend.copyCount == 1)
        // And it is the *last* row, not the first: a scheduler that kept the earliest request would
        // put a file the cursor has left on screen under the current row's name.
        #expect(cache.cachedURL(for: Fixture.entry("e.txt")) != nil)
        #expect(cache.cachedURL(for: Fixture.entry("a.txt")) == nil)
    }

    /// The second bound, cheap half: leaving before the delay elapses means the request is never
    /// issued at all.
    @Test("leaving the row before the settle delay transfers nothing at all")
    func leavingTheRowTransfersNothing() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        cache.cancelAutomaticFetch()
        await hold()

        #expect(backend.copyCount == 0)
        #expect(cache.previewFetchState(for: entry) == nil)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    /// The second bound, and the half that actually bounds anything: a transfer **already on the
    /// wire** is abandoned when the cursor leaves. This is what makes a 16 MiB cap safe rather than
    /// merely small — the user pays for the seconds they spent looking at the row, not for the file.
    ///
    /// It needs a transfer slow enough to leave *during*, which is why the fake blocks. Every other
    /// test here finishes inside the same turn, so all of them are satisfied by the scheduler's
    /// identity guard and none of them can see whether cancellation reaches the transfer at all —
    /// measured, by neutering `cancelAutomaticFetch` and watching the whole suite stay green.
    @Test("leaving the row abandons a transfer that is already running")
    func leavingTheRowAbandonsARunningTransfer() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        await settle { backend.copyCount == 1 }
        #expect(backend.copyCount == 1)

        cache.cancelAutomaticFetch()
        await settle { backend.wasCancelledMidTransfer }

        #expect(backend.wasCancelledMidTransfer)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    @Test("a landed automatic fetch reports itself and leaves the copy served")
    func landedFetchReportsAndCaches() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let settled = Landing()

        #expect(cache.previewFetchState(for: entry) == nil)
        cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        // Immediately, not once the bytes arrive: the placeholder card drawn on this very delivery
        // has to say a download is on its way rather than that none is.
        #expect(cache.previewFetchState(for: entry) == .running)
        await settle { settled.times > 0 }

        #expect(settled.times == 1)
        #expect(cache.cachedURL(for: entry) != nil)
        // Cleared on success, so the next delivery reads "nothing pending" and finds the bytes.
        #expect(cache.previewFetchState(for: entry) == nil)
    }

    /// A failure is reported to the caller once and then *remembered*, and both halves matter. The
    /// report is what stops the card claiming a download is still coming; the memory is what stops
    /// the re-delivery that report causes from starting the same doomed transfer again — an
    /// unattended retry loop against a server, which is the expensive direction.
    @Test("a failed automatic fetch reports once and is not retried by the delivery it causes")
    func failedFetchReportsOnceAndDoesNotLoop() async {
        let backend = CountingBackend(outcome: .fail)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")
        let settled = Landing()

        cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        await settle { settled.times > 0 }
        #expect(cache.previewFetchState(for: entry) == .failed)

        // What every later preview delivery for this row does — including the one the report above
        // triggered.
        for _ in 0..<3 {
            cache.scheduleAutomaticFetch(entry, using: backend) { settled.times += 1 }
        }
        // Paced by a fetch that must issue rather than by a constant: a `hold()` here reads as six
        // times the 400 ms settle delay and expired before it in a full run, leaving this passing
        // with the guard deleted (▸ ``holdOutTheAutomaticFetchDelay()``).
        await holdOutTheAutomaticFetchDelay()

        #expect(backend.copyCount == 1)
        #expect(settled.times == 1)
    }

    /// The state belongs to *a row*, not to the cache: a card is drawn per cursor position, and one
    /// that read a neighbour's pending fetch would say a download was on its way for a file nothing
    /// had been asked about.
    @Test("the pending state answers only for the row it belongs to")
    func pendingStateIsPerRow() async {
        let backend = CountingBackend()
        let cache = RemoteFileCache()

        cache.scheduleAutomaticFetch(Fixture.entry("a.txt"), using: backend, onSettled: {})

        #expect(cache.previewFetchState(for: Fixture.entry("a.txt")) == .running)
        #expect(cache.previewFetchState(for: Fixture.entry("b.txt")) == nil)
        cache.cancelAutomaticFetch()
        await hold()
    }

    /// Stop has to be *remembered*, and this is the assertion that says the button works at all.
    ///
    /// Pressing it re-draws the card, and a re-draw is a preview delivery — which schedules the row
    /// again. So a Stop that merely forgot the fetch would restart it within the same turn, and a
    /// file under the limit could not be stopped at all: every cursor step would re-issue what had
    /// just been called off. The `.stopped` state is what makes the second schedule a no-op.
    @Test("Stop is remembered, so the delivery it causes does not start the download again")
    func stopIsNotRestartedByItsOwnRedraw() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        await settle { backend.copyCount == 1 }
        cache.stopPreviewFetch()

        #expect(cache.previewFetchState(for: entry) == .stopped)
        // What the redraw does, and what every later cursor step on this row would do.
        for _ in 0..<3 {
            cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        }
        await holdOutTheAutomaticFetchDelay()

        #expect(backend.copyCount == 1)
        // Settled by the stop already in flight rather than by a delay: the transfer notices on its
        // next 10 ms poll, so this is a wait *for* something and free to be generous.
        await settle { backend.wasCancelledMidTransfer }
        #expect(backend.wasCancelledMidTransfer)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    /// The other half: moving the cursor away forgets it, so coming back offers the file afresh
    /// rather than leaving it permanently marked as one the user once stopped.
    @Test("moving the cursor away forgets a stopped row")
    func movingAwayForgetsAStoppedRow() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        await settle { backend.copyCount == 1 }
        cache.stopPreviewFetch()
        cache.cancelAutomaticFetch()

        #expect(cache.previewFetchState(for: entry) == nil)
    }

    /// What the card's progress bar reads while a download runs. The transfer reports from its own
    /// thread and the card asks whenever it next draws, so the claim is that the two meet at all —
    /// a counter that stayed at zero would draw a bar that never moves, which on a slow connection
    /// is the exact impression the indicator exists to prevent.
    @Test("a running fetch reports how far it has got, for its own row only")
    func runningFetchReportsProgress() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("a.txt")

        // Nothing running: no number, rather than a zero that would draw as a stalled bar.
        #expect(cache.previewFetchProgress(for: entry) == nil)
        cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        await settle { cache.previewFetchProgress(for: entry) == CountingBackend.blockedChunk }

        #expect(cache.previewFetchProgress(for: entry) == CountingBackend.blockedChunk)
        #expect(cache.previewFetchProgress(for: Fixture.entry("b.txt")) == nil)

        cache.cancelAutomaticFetch()
        await settle { backend.wasCancelledMidTransfer }
        #expect(cache.previewFetchProgress(for: entry) == nil)
    }

    /// Poll until `isDone` — `await`, never a run-loop spin, since what is being waited for is a
    /// transfer's continuation and a spin never suspends the main actor (docs/NOTES.md ▸ Testing).
    ///
    /// Generous on purpose, and it costs nothing: a satisfied predicate returns on the next poll,
    /// so the budget only decides how much scheduling delay the test absorbs before reporting a
    /// failure that is really the machine's. Waiting a delay *out* is ``hold(until:)`` instead.
    @discardableResult
    private func settle(within seconds: Double = 10, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isDone()
    }

    /// Wait out the settle delay to show something does *not* happen, giving up early if it ever
    /// does. Bounded, unlike ``settle(within:until:)``: here the length is the claim, so it cannot
    /// be widened to suit a slow machine.
    private func hold(until isHappening: () -> Bool = { false }) async {
        _ = await settle(within: 2, until: isHappening)
    }
}
