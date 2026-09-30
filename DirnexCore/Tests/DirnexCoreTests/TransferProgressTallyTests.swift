import Testing

@testable import DirnexCore

/// The arithmetic every remote transport reports progress through.
///
/// Each rule here is one a transport used to spell out for itself, and each fails quietly when it is
/// spelled wrong: a bar that walks backwards, a resumed transfer that claims bytes the user already
/// had, or a job whose total is a sum of one-per-cent estimates rather than the count the tool
/// measured.
@Suite("transfer progress tally")
struct TransferProgressTallyTests {
    // MARK: - A destination file that grows

    @Test("a growing destination reports the difference, not the size")
    func reportsDeltasFromAFile() {
        var tally = TransferProgressTally()
        #expect(tally.delta(forDestinationSize: 0) == nil, "nothing has landed yet")
        #expect(tally.delta(forDestinationSize: 2_097_152) == 2_097_152)
        #expect(tally.delta(forDestinationSize: 4_194_304) == 2_097_152)
        #expect(
            tally.delta(forDestinationSize: 4_194_304) == nil,
            "the poll caught it standing still"
        )
        #expect(tally.remainder(against: 4_194_304) == nil)
    }

    @Test("a resume reports only what this transfer moved")
    func resumeDoesNotRecountWhatWasAlreadyThere() {
        // The destination already holds a megabyte from an interrupted run.
        var tally = TransferProgressTally(destinationAlreadyHolds: 1_048_576)
        #expect(tally.delta(forDestinationSize: 1_048_576) == nil, "those bytes are not this run's")
        #expect(tally.delta(forDestinationSize: 1_572_864) == 524_288)
        #expect(tally.remainder(against: 524_288) == nil)
    }

    /// `curl` and `sftp` both truncate a partial they are *not* resuming from, so a destination that
    /// shrinks means the baseline is gone and everything arriving now is new. Without this a fresh
    /// download over an old partial reports nothing until it passes the old file's length.
    @Test("a destination that shrinks is a fresh transfer, not a negative one")
    func truncationResetsTheBaseline() {
        var tally = TransferProgressTally(destinationAlreadyHolds: 900)
        #expect(tally.delta(forDestinationSize: 0) == nil, "truncated: nothing has been moved yet")
        #expect(tally.delta(forDestinationSize: 400) == 400)
        #expect(tally.delta(forDestinationSize: 1000) == 600)
        #expect(tally.remainder(against: 1000) == nil)
    }

    // MARK: - A meter that counts upward

    @Test("an estimate that has not advanced reports nothing")
    func meterOnlyReportsForward() {
        var tally = TransferProgressTally()
        #expect(tally.delta(movedSoFar: 290_000) == 290_000)
        #expect(tally.delta(movedSoFar: 290_000) == nil)
        #expect(
            tally.delta(movedSoFar: 100) == nil,
            "a bar that has drawn those bytes cannot un-draw them"
        )
        #expect(tally.delta(movedSoFar: 580_000) == 290_000)
    }

    // MARK: - Reconciling with the exact count

    @Test("the remainder is what turns estimates into the measured total")
    func remainderClosesTheGap() {
        var tally = TransferProgressTally()
        tally.add(7_250_000)
        tally.add(14_210_000)
        #expect(tally.remainder(against: 29_000_000) == 7_540_000)
        #expect(tally.remainder(against: 29_000_000) == nil)
    }

    @Test("a transfer that streamed nothing reports the whole count at the end")
    func remainderCoversASilentTransfer() {
        var tally = TransferProgressTally()
        #expect(tally.remainder(against: 4096) == 4096)
    }

    /// An upload's estimate is a percentage of the size the file had when it started, so it can
    /// overshoot a short write. Left standing rather than corrected: the reconciliation's job is to
    /// never report a finished transfer as *less* than what was measured.
    @Test("an estimate that overshot the measured count is not taken back")
    func overshootIsNotReversed() {
        var tally = TransferProgressTally()
        tally.add(1200)
        #expect(tally.remainder(against: 1000) == nil)
        #expect(tally.remainder(against: 1200) == nil)
    }
}
