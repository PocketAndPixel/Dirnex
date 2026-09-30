import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The queue bar's one piece of state that outlives a batch: the fill it was last drawn with.
///
/// Nothing on the bar is a live reading — the fraction, the byte readout and the status line all
/// come from a snapshot and stay until the next one replaces them — so a drained queue leaves the
/// *previous* batch's numbers standing on a bar that is merely off screen. The next batch then
/// reveals them for a frame before its own first snapshot lands. Measured in the running app
/// 2026-08-19: the second copy of a file unhid the bar still reading `1.0` and only then set it to
/// `0`, which is what a user reported as a bar that "starts at 100 %, drops to zero, and only then
/// runs". The inherited value is whatever was last *drawn*, not necessarily full — a transfer that
/// reports its final bytes together with its completion (an S3 upload does) hands the next batch
/// something nearer half, which is the other half of that report.
@MainActor
@Suite("Queue bar reset")
struct QueueBarResetTests {
    private func running(totalBytes: Int64, completedBytes: Int64) -> QueueSnapshot {
        let progress = OperationProgress(
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            totalItems: 1,
            completedItems: 0,
            currentItem: VFSPath.local("/tmp/huge.bin")
        )
        return QueueSnapshot(
            jobs: [JobSnapshot(
                id: OperationJobID(), kind: .copy, status: .running, progress: progress, report: nil
            )],
            aggregate: AggregateProgress(
                totalJobs: 1,
                finishedJobs: 0,
                activeJobs: 1,
                totalBytes: totalBytes,
                completedBytes: completedBytes,
                totalItems: 1,
                completedItems: 0,
                bytesPerSecond: 0,
                estimatedTimeRemaining: nil
            ),
            isPaused: false
        )
    }

    /// The batch that just drained, as the queue publishes it: every job terminal, the bytes all
    /// counted. This is the snapshot the window controller hides the bar on.
    private func drained(totalBytes: Int64) -> QueueSnapshot {
        QueueSnapshot(
            jobs: [JobSnapshot(
                id: OperationJobID(),
                kind: .copy,
                status: .finished,
                progress: OperationProgress(
                    totalBytes: totalBytes,
                    completedBytes: totalBytes,
                    totalItems: 1,
                    completedItems: 1,
                    currentItem: nil
                ),
                report: nil
            )],
            aggregate: AggregateProgress(
                totalJobs: 1,
                finishedJobs: 1,
                activeJobs: 0,
                totalBytes: totalBytes,
                completedBytes: totalBytes,
                totalItems: 1,
                completedItems: 1,
                bytesPerSecond: 0,
                estimatedTimeRemaining: nil
            ),
            isPaused: false
        )
    }

    private func makeBar() -> QueueBarView {
        QueueBarView(frame: .init(x: 0, y: 0, width: 600, height: 64))
    }

    @Test("an idle snapshot empties the bar instead of drawing")
    func idleResetsTheFill() {
        let bar = makeBar()
        bar.update(with: running(totalBytes: 400, completedBytes: 200))
        #expect(bar.progressFraction == 0.5, "the running batch is drawn")

        bar.update(with: drained(totalBytes: 400))
        #expect(bar.progressFraction == 0, "the drained batch leaves nothing behind")
        #expect(bar.detailReadout.isEmpty, "…including its byte readout")
    }

    /// The bug as the user meets it: two batches, back to back. What the second one must never do is
    /// open on the first one's fill.
    @Test("a second batch opens empty rather than on the first batch's fill")
    func aSecondBatchStartsFromZero() {
        let bar = makeBar()
        bar.update(with: running(totalBytes: 400, completedBytes: 400))
        bar.update(with: drained(totalBytes: 400))

        // The next batch's enqueue publish: a job with nothing measured yet, which is the moment
        // the window controller unhides the bar.
        let enqueued = QueueSnapshot(
            jobs: [JobSnapshot(
                id: OperationJobID(), kind: .copy, status: .waiting, progress: nil, report: nil
            )],
            aggregate: AggregateProgress(
                totalJobs: 1,
                finishedJobs: 0,
                activeJobs: 0,
                totalBytes: 0,
                completedBytes: 0,
                bytesPerSecond: 0,
                estimatedTimeRemaining: nil
            ),
            isPaused: false
        )
        #expect(bar.progressFraction == 0, "the fill is already empty when the bar reappears")
        bar.update(with: enqueued)
        #expect(bar.progressFraction == 0)
    }

    /// The coalescer's memo is the second half of the same staleness, and it is the half a fill
    /// assertion cannot see: `lastDetailRefresh` decides whether the *next* batch's first readout is
    /// drawn or deferred, so without clearing it a copy started within a second of the last one
    /// opens on the previous batch's byte count and holds it for up to a second.
    @Test("the readout of a batch started straight after the last one is drawn at once")
    func theCoalescingMemoIsClearedToo() {
        let bar = makeBar()
        bar.update(with: running(totalBytes: 400, completedBytes: 400))
        bar.update(with: drained(totalBytes: 400))

        bar.update(with: running(totalBytes: 29_000_000, completedBytes: 0))
        #expect(
            bar.detailReadout.contains("29"),
            "the new batch's readout was deferred behind the old batch's: \(bar.detailReadout)"
        )
    }
}
