import Testing
@testable import DirnexCore

/// The rules for what a drag of remote rows offers as the pointer moves between apps. Each is pinned
/// by the failure it stands against, measured against real Finder and Teams drops 2026-11-03.
@Suite("Remote drag handoff")
struct RemoteDragHandoffTests {
    private let finder = RemoteDragHandoff.Surface.finder(processID: 10)
    private let teams = RemoteDragHandoff.Surface.otherApp(processID: 20)
    private let slack = RemoteDragHandoff.Surface.otherApp(processID: 30)

    /// A handoff whose pointer has reached `surface`, for the tests about what follows.
    private func entered(_ surface: RemoteDragHandoff.Surface) -> RemoteDragHandoff {
        var handoff = RemoteDragHandoff()
        _ = handoff.pointerMoved(over: surface)
        return handoff
    }

    // MARK: - Who is what

    @Test("Finder is told apart by its bundle identifier")
    func classifiesFinder() {
        let surface = RemoteDragHandoff.Surface.classify(
            processID: 10, bundleIdentifier: "com.apple.finder", isRegularApp: true, ownProcessID: 1
        )
        #expect(surface == .finder(processID: 10))
    }

    @Test("Any other regular app may only understand a file URL")
    func classifiesOtherApps() {
        let surface = RemoteDragHandoff.Surface.classify(
            processID: 20, bundleIdentifier: "com.microsoft.teams2", isRegularApp: true,
            ownProcessID: 1
        )
        #expect(surface == .otherApp(processID: 20))
    }

    @Test("Dirnex itself is neutral, because it reads its own payload")
    func classifiesOwnWindows() {
        let surface = RemoteDragHandoff.Surface.classify(
            processID: 1, bundleIdentifier: "app.dirnex.Dirnex", isRegularApp: true, ownProcessID: 1
        )
        #expect(surface == .neutral)
    }

    @Test("A background helper is neutral, so it never starts a download")
    func classifiesHelpers() {
        let surface = RemoteDragHandoff.Surface.classify(
            processID: 40, bundleIdentifier: "com.apple.dock", isRegularApp: false, ownProcessID: 1
        )
        #expect(surface == .neutral)
    }

    // MARK: - Leaving the promise

    @Test("Finder leaves the promise alone and costs nothing")
    func finderKeepsThePromise() {
        var handoff = RemoteDragHandoff()
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        #expect(handoff.board == .promises)
        #expect(handoff.transfer == .notStarted)
    }

    @Test("Dirnex's own windows leave the promise alone")
    func neutralKeepsThePromise() {
        var handoff = RemoteDragHandoff()
        #expect(handoff.pointerMoved(over: .neutral).isEmpty)
        #expect(handoff.board == .promises)
    }

    @Test("Another app gets a lazy board and starts the transfer, in that order")
    func otherAppLeavesThePromise() {
        var handoff = RemoteDragHandoff()
        #expect(handoff.pointerMoved(over: teams) == [.writeLazyFileURLs, .startTransfer])
        #expect(handoff.board == .lazyFileURLs)
        #expect(handoff.transfer == .running)
    }

    @Test("Staying over the same app asks for nothing more")
    func movingWithinAnAppIsFree() {
        var handoff = entered(teams)
        #expect(handoff.pointerMoved(over: teams).isEmpty)
    }

    /// Written back after a rewrite, a promise makes Finder report a copy and deliver nothing, so the
    /// board must not try. Finder reads the lazy URL from here on, as anybody else does.
    @Test("Coming back over Finder does not bring the promise back")
    func theRewriteIsOneWay() {
        var handoff = entered(teams)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
        #expect(handoff.board == .lazyFileURLs)
    }

    // MARK: - Answering a read

    @Test("A read waits while the bytes are on their way")
    func readWaitsForTheTransfer() {
        var handoff = entered(teams)
        #expect(handoff.readFileURL(from: teams) == .wait)
    }

    @Test("A read after the bytes landed gets the file, and the board need not change")
    func readAfterLanding() {
        var handoff = entered(teams)
        #expect(handoff.transferLanded().isEmpty)
        #expect(handoff.board == .lazyFileURLs)
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    @Test("A hold that ran out tells that app nothing")
    func holdRunsOut() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.readFileURL(from: teams) == .nothing)
    }

    /// A drop of three that quietly attached two would look like success.
    @Test("Every row of a board shares the first row's answer")
    func rowsShareOneAnswer() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.readFileURL(from: teams) == .nothing)
        _ = handoff.transferLanded()
        // The bytes landing replaces the board, and the old board's rows are gone with it. A read
        // that still arrives is answered as the new board would be.
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    @Test("A failed transfer tells a reader nothing rather than holding it")
    func failedTransferAnswersAtOnce() {
        var handoff = entered(teams)
        handoff.transferFailed()
        #expect(handoff.readFileURL(from: teams) == .nothing)
    }

    @Test("A hold ending after the bytes landed changes nothing")
    func holdEndingLate() {
        var handoff = entered(teams)
        _ = handoff.transferLanded()
        handoff.holdEnded(over: teams)
        #expect(handoff.readFileURL(from: teams) == .fileURLs)
    }

    // MARK: - After "nothing"

    /// A lazy type answered empty is never asked again, so the board has to be replaced, and it is
    /// what lets a slow file reach Teams at all: measured, Teams took it on the way back in.
    @Test("The bytes landing replaces a board that already said nothing")
    func landingReplacesARefusedBoard() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.transferLanded() == [.writeFileURLs])
        #expect(handoff.board == .fileURLs)
        #expect(handoff.pointerMoved(over: teams).isEmpty)
    }

    @Test("A different app gets a fresh board and its own wait")
    func anotherAppGetsItsOwnChance() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.pointerMoved(over: slack) == [.writeLazyFileURLs])
        #expect(handoff.readFileURL(from: slack) == .wait)
    }

    @Test("Finder also gets a fresh board, or it would refuse an answer it never asked for")
    func finderGetsAFreshBoardToo() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.pointerMoved(over: finder) == [.writeLazyFileURLs])
        #expect(handoff.readFileURL(from: finder) == .wait)
    }

    /// Without this the board would be rewritten at every move, for an app that will never look.
    @Test("The app that was told nothing does not get a new board until the bytes land")
    func theSameAppKeepsItsAnswer() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        #expect(handoff.pointerMoved(over: teams).isEmpty)
        #expect(handoff.pointerMoved(over: .neutral).isEmpty)
        #expect(handoff.pointerMoved(over: teams).isEmpty)
    }

    @Test("Nothing is rewritten for another app once the transfer has failed")
    func failureStaysFailed() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        handoff.transferFailed()
        #expect(handoff.pointerMoved(over: slack).isEmpty)
    }

    @Test("A board of real URLs is final")
    func fileURLsAreFinal() {
        var handoff = entered(teams)
        handoff.holdEnded(over: teams)
        _ = handoff.transferLanded()
        #expect(handoff.pointerMoved(over: slack).isEmpty)
        #expect(handoff.pointerMoved(over: finder).isEmpty)
    }

    // MARK: - The drag ending

    @Test("A running transfer that may not finish unasked is stopped")
    func endStopsALargeTransfer() {
        var handoff = entered(teams)
        #expect(handoff.dragEnded(mayFinish: false) == [.stopTransfer])
    }

    @Test("A running transfer that may finish is left to, so a second try is immediate")
    func endLeavesASmallTransfer() {
        var handoff = entered(teams)
        #expect(handoff.dragEnded(mayFinish: true).isEmpty)
    }

    @Test("A drag that never left the promise has nothing to stop")
    func endWithNoTransfer() {
        var handoff = RemoteDragHandoff()
        #expect(handoff.dragEnded(mayFinish: false).isEmpty)
    }

    @Test("A transfer that already landed has nothing to stop")
    func endAfterLanding() {
        var handoff = entered(teams)
        _ = handoff.transferLanded()
        #expect(handoff.dragEnded(mayFinish: false).isEmpty)
    }
}
