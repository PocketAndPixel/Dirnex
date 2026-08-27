import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the funnel behind Open With and Share does with a marked set (PLAN.md §M24 Slice 3).
///
/// Seven gestures refused anything but a local file, each in one line, and these two are the first
/// to stop. What has to hold now is a set of claims that pull in opposite directions, which is why
/// they are pinned together: the ordinary marked set of local files must reach the other application
/// with **no job, no dialog and no delay**, a set that is not here must be fetched and handed over
/// as the *copies*, and a set that only half arrives must not be handed over at all.
///
/// The transfer itself is not under test — `MaterializeRunner` owns it and is tested in the core
/// against a real backend. What an app test can see, and what a whole milestone rests on, is which
/// rows the **gesture** queued and what it then did with the answer, so the host is a stub that
/// records the first and is told what to answer for the second.
@MainActor
@Suite("Materializing a hand-off")
struct HandoffMaterializeTests {
    // MARK: - The ordinary set, which must cost nothing

    /// The control that keeps every other claim here from being bought at the price of the common
    /// case: a marked set of plain local files reaches the other application in the same turn, with
    /// nothing queued and nothing asked.
    @Test("a set already on this disk is handed over at once, with no job")
    func localSetIsHandedOverSynchronously() {
        let (pane, host) = hostedPane()
        let rows = [Handoff.local("/tmp/a.txt"), Handoff.local("/tmp/b.txt")]
        let handed = Handed()

        pane.materialize(rows, for: .handOff, failureMessage: neverAsked) { handed.take($0) }

        #expect(handed.urls?.map(\.path) == ["/tmp/a.txt", "/tmp/b.txt"])
        #expect(host.materializedEntries.isEmpty)
    }

    /// An evicted placeholder is handed over as **itself**, and nothing is queued for it: those
    /// bytes are the file provider's to fetch when the receiving application reads the file, which
    /// is what Finder does with the same row.
    @Test("a cloud placeholder is handed over as its own path, with nothing asked")
    func placeholderIsHandedOverAsItself() {
        let hosted = windowedPane()
        let (pane, host, window) = (hosted.pane, hosted.host, hosted.window)
        // Two gigabytes, deliberately: it is far over the threshold, so counting it would raise the
        // confirmation — which is the only thing the rule changes, and therefore the only thing a
        // control can fail on. `beginSheetModal` sets `attachedSheet` synchronously (measured at
        // ~2 µs, docs/NOTES.md ▸ Testing), so reading it straight afterwards is exact rather than a
        // wait that could expire.
        let placeholder = Handoff.entry(
            .local("/tmp/evicted.raw"), size: 2_000_000_000, isDataless: true
        )
        let handed = Handed()

        pane.materialize([placeholder], for: .handOff, failureMessage: neverAsked) {
            handed.take($0)
        }

        #expect(handed.urls?.map(\.path) == ["/tmp/evicted.raw"])
        #expect(host.materializedEntries.isEmpty)
        #expect(window.attachedSheet == nil)
    }

    // MARK: - A set that has to be fetched

    @Test("a remote set is queued, and what is handed over is the copies")
    func remoteSetIsQueuedAndCopiesAreHandedOver() throws {
        let (pane, host) = hostedPane()
        let row = Handoff.remote("/srv/report.pdf")
        let copy = try Handoff.temporaryFile(named: "report.pdf")
        host.materializeReport = Handoff.report(landing: [(row, copy)])
        let handed = Handed()

        pane.materialize([row], for: .handOff, failureMessage: neverAsked) { handed.take($0) }

        #expect(host.materializedEntries.map { $0.map(\.path) } == [[row.path]])
        #expect(handed.urls == [copy])
    }

    /// The second gesture over the same rows must transfer nothing — the copies were adopted into
    /// the window's cache, which is the whole reason the runner hands them back rather than filing
    /// them itself.
    @Test("a row already fetched is not queued again")
    func aFetchedRowIsNotQueuedTwice() throws {
        let (pane, host) = hostedPane()
        let row = Handoff.remote("/srv/report.pdf")
        let copy = try Handoff.temporaryFile(named: "report.pdf")
        host.materializeReport = Handoff.report(landing: [(row, copy)])
        let handed = Handed()
        pane.materialize([row], for: .handOff, failureMessage: neverAsked) { _ in }

        pane.materialize([row], for: .handOff, failureMessage: neverAsked) { handed.take($0) }

        #expect(host.materializedEntries.count == 1)
        #expect(handed.urls == [copy])
    }

    /// Stop is the user's own answer and it is already on screen in the queue bar: nothing is handed
    /// over, and nothing is reported either.
    @Test("a stopped transfer hands nothing over and says nothing")
    func aStoppedTransferHandsNothingOver() {
        let (pane, host) = hostedPane()
        host.materializeReport = Handoff.report(cancelled: true)
        let handed = Handed()

        pane.materialize(
            [Handoff.remote("/srv/report.pdf")],
            for: .handOff,
            failureMessage: neverAsked
        ) { handed.take($0) }

        #expect(handed.times == 0)
        #expect(host.materializedEntries.count == 1)
    }

    /// A hand-off hands over what the user marked, so a set that only half arrived is a failure
    /// rather than a smaller success — `MaterializeRunner` deliberately carries on past a failed row
    /// and names it, leaving the decision here, and this is that decision.
    @Test("a set that only half arrived is not handed over")
    func aPartialSetIsAFailure() throws {
        let hosted = windowedPane()
        let (pane, host, window) = (hosted.pane, hosted.host, hosted.window)
        let landed = Handoff.remote("/srv/one.pdf")
        let lost = Handoff.remote("/srv/two.pdf")
        let copy = try Handoff.temporaryFile(named: "one.pdf")
        host.materializeReport = Handoff.report(landing: [(landed, copy)], failing: [lost])
        let handed = Handed()
        var wordedFailure = false

        pane.materialize([landed, lost], for: .handOff) {
            wordedFailure = true
            return "couldn’t"
        } then: { handed.take($0) }

        #expect(handed.times == 0)
        #expect(wordedFailure)
        // And it says so, rather than doing nothing: the pane looks exactly as it did, so a silent
        // give-up is indistinguishable from the key not having been pressed.
        #expect(window.attachedSheet != nil)
        // Naming the **server's** reason, not the fallback sentence. Both refuse the hand-off, so
        // without this the test cannot tell the useful message from the vague one — which is
        // exactly what a control on the reporting would change.
        #expect(sheetText(in: window).contains(pane.describe(VFSError.notFound(lost.path))))
    }

    // MARK: - Where a report meets the gesture that asked for it

    /// The pairing that makes the queued job's answer reach its gesture whichever way round the two
    /// halves arrive. `FileOperationQueue.enqueue` is an actor method, so the id the two share
    /// exists only *after* the job has been accepted and could already have run to completion — a
    /// transfer that fails on its first request beats the caller writing down what to do about it.
    @Test("a report is delivered whichever half arrives first")
    func deliveriesPairInBothOrders() {
        let deliveries = MaterializeDeliveries()
        let waitingFirst = OperationJobID()
        let reportFirst = OperationJobID()
        let seen = Handed()

        deliveries.expect(waitingFirst) { _ in seen.times += 1 }
        deliveries.deliver(.empty, for: waitingFirst)
        #expect(seen.times == 1)

        deliveries.deliver(.empty, for: reportFirst)
        #expect(seen.times == 1)
        deliveries.expect(reportFirst) { _ in seen.times += 1 }
        #expect(seen.times == 2)
    }
}
