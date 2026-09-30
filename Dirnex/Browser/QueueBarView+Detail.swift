import AppKit
import DirnexCore

/// The queue bar's byte/throughput/ETA readout, and the one rule it has.
///
/// Split out of `QueueBarView` when the file reached SwiftLint's 500-line ceiling, along the same
/// kind of seam `QueueBarView+Status` took: everything here is the *readout* — how it is worded, how
/// often it is allowed to change, and what happens to a value that arrives too soon — while the view
/// around it is geometry. The stored state stays in the class because a Swift extension cannot hold
/// any, and widened to internal for the same reason `private` does not cross files (docs/NOTES.md ▸
/// Lint ceilings and file splitting).
extension QueueBarView {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let etaFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    /// What the byte/throughput/ETA line currently says. The assertion surface for the coalescing
    /// rule (`QueueBarView.pendingDetail`), which is otherwise only observable by looking at the
    /// window.
    var detailReadout: String { detailLabel.stringValue }

    /// Draw the readout now, and drop any deferred one — it is older than what is being drawn.
    func drawDetail(_ aggregate: AggregateProgress, paused: Bool) {
        detailFlushTimer?.invalidate()
        detailFlushTimer = nil
        pendingDetail = nil
        detailLabel.stringValue = detailText(for: aggregate, paused: paused)
        lastDetailRefresh = Date()
        lastPausedState = paused
    }

    /// Hold a readout that arrived too soon and arm a timer to draw it when the interval is up.
    ///
    /// The timer is what makes this a *deferral*: it fires whether or not another update ever
    /// arrives, which is exactly the case the dropped version could not survive. It runs in
    /// `.common` modes so a readout is not frozen while a menu is open or a pane is being scrolled,
    /// and re-arming is left to the existing timer — the pending value is simply replaced, so a
    /// burst of updates still draws once.
    func deferDetail(_ aggregate: AggregateProgress, paused: Bool) {
        pendingDetail = (aggregate, paused)
        guard detailFlushTimer == nil else { return }
        let due = Self.detailRefreshInterval - Date().timeIntervalSince(lastDetailRefresh)
        let timer = Timer(timeInterval: max(0, due), repeats: false) { [weak self] _ in
            // A main-runloop timer fires on the main thread by construction, so the assumption holds.
            MainActor.assumeIsolated {
                guard let self, let pending = self.pendingDetail else { return }
                self.drawDetail(pending.aggregate, paused: pending.paused)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        detailFlushTimer = timer
    }

    /// The byte/throughput/ETA readout beneath the status line, `·`-joined.
    func detailText(for aggregate: AggregateProgress, paused: Bool) -> String {
        let done = Self.byteFormatter.string(fromByteCount: aggregate.completedBytes)
        let total = Self.byteFormatter.string(fromByteCount: aggregate.totalBytes)
        // The comment is repeated verbatim at the Quick View placeholder card, which keys the same
        // string: `String(localized:comment:)` takes a `StaticString`, so a shared comment cannot be
        // hoisted, and two sites keying one string with *different* comments hand the translator
        // whichever one `xcstringstool` kept (docs/NOTES.md ▸ Localization).
        var parts = [String(
            localized: "\(done) of \(total)",
            comment: "Byte readout: %1$@ transferred of %2$@ total, both already formatted."
        )]
        if !paused, aggregate.bytesPerSecond > 0 {
            let rate = Self.byteFormatter.string(fromByteCount: Int64(aggregate.bytesPerSecond))
            parts.append(String(
                localized: "\(rate)/s",
                comment: "Queue-bar throughput readout; %@ is a byte count, e.g. “1.2 MB/s”."
            ))
            if let eta = aggregate.estimatedTimeRemaining, let text = Self.etaFormatter.string(
                from: eta
            ) {
                parts.append(String(
                    localized: "\(text) left",
                    comment: "Queue-bar ETA readout; %@ is a formatted duration, e.g. “2 min left”."
                ))
            }
        }
        return parts.joined(separator: " · ")
    }
}
