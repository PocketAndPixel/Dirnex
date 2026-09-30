import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The queue bar's byte readout, and the one rule it has: coalescing may **defer** an update, never
/// drop it.
///
/// Dropping is what shipped, and it latches. A job publishes the moment it is enqueued — nothing
/// scanned yet, so the honest readout is `Zero KB of Zero KB` — and again microseconds later
/// carrying the real total. The second update lands inside the first one's second and, dropped,
/// leaves the stale text standing until something else publishes. For a local copy something always
/// does, every 8 MiB; a remote transfer publishes about once a second at best and, before the
/// progress work in this same pass, not at all until it finished. Reported 2026-08-14 as an S3 copy
/// that showed `Zero KB of Zero KB` for its whole duration while the status line beside it correctly
/// named the file being copied — which is the tell, since both are drawn from the same snapshot.
@MainActor
@Suite("Queue bar detail readout")
struct QueueBarDetailReadoutTests {
    private func snapshot(totalBytes: Int64, completedBytes: Int64 = 0) -> QueueSnapshot {
        let progress = totalBytes == 0 && completedBytes == 0
            ? nil
            : OperationProgress(
                totalBytes: totalBytes,
                completedBytes: completedBytes,
                totalItems: 1,
                completedItems: 0,
                currentItem: VFSPath.local("/tmp/DSC_0002.NEF")
            )
        let job = JobSnapshot(
            id: OperationJobID(),
            kind: .copy,
            status: .running,
            progress: progress,
            report: nil
        )
        return QueueSnapshot(
            jobs: [job],
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

    /// Poll rather than spin the run loop, and poll rather than sleep once: the deferred draw is a
    /// timer, so what is being waited for is the main run loop getting a turn (docs/NOTES.md ▸
    /// Testing).
    private func waitForReadout(
        _ bar: QueueBarView,
        toContain needle: String,
        within seconds: Double = 4
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if bar.detailReadout.contains(needle) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return bar.detailReadout.contains(needle)
    }

    @Test("a total that arrives inside the coalescing window is drawn, not dropped")
    func aDeferredReadoutIsStillDrawn() async {
        let bar = QueueBarView(frame: .init(x: 0, y: 0, width: 600, height: 64))

        // The enqueue publish: a job with nothing measured yet.
        bar.update(with: snapshot(totalBytes: 0))
        #expect(bar.detailReadout.contains("Zero KB"), "nothing is known yet, and it says so")

        // The engine's own first emits, microseconds later and inside the same second.
        bar.update(with: snapshot(totalBytes: 29_000_000))
        bar.update(with: snapshot(totalBytes: 29_000_000))

        // Nothing else will ever publish — the transfer is one long invocation. The readout has to
        // arrive on its own or not at all.
        let drawn = await waitForReadout(bar, toContain: "29")
        #expect(drawn, "the deferred total never reached the label: \(bar.detailReadout)")
    }

    @Test("a burst inside one window still draws once, and draws the newest value")
    func aBurstCollapsesToTheLatest() async {
        let bar = QueueBarView(frame: .init(x: 0, y: 0, width: 600, height: 64))
        bar.update(with: snapshot(totalBytes: 0))
        for completed in stride(from: Int64(1_000_000), through: 9_000_000, by: 1_000_000) {
            bar.update(with: snapshot(totalBytes: 29_000_000, completedBytes: completed))
        }

        // Coalescing is still doing its job: what lands is the last value, not nine repaints.
        let drawn = await waitForReadout(bar, toContain: "29")
        #expect(drawn, "the deferred total never reached the label: \(bar.detailReadout)")
        #expect(bar.detailReadout.contains("9"), "the newest completed count, not the first")
    }

    @Test("an update that arrives after the window is drawn immediately")
    func anUpdateOutsideTheWindowNeedsNoTimer() async {
        let bar = QueueBarView(frame: .init(x: 0, y: 0, width: 600, height: 64))
        bar.update(with: snapshot(totalBytes: 0))
        try? await Task.sleep(for: .milliseconds(1100))
        bar.update(with: snapshot(totalBytes: 29_000_000))
        #expect(bar.detailReadout.contains("29"), "no deferral was needed: \(bar.detailReadout)")
    }
}
