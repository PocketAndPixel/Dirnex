import Foundation

/// Remembers that one connection's server will not serve a download in several pieces, so the next
/// file does not pay to find out again.
///
/// **The cost this avoids was measured, and it is bytes rather than a round trip.** A server that
/// caps concurrent connections does not refuse the whole run up front: it serves the sections that
/// fit and refuses the rest, so the pieces that *did* arrive are downloaded in full and then thrown
/// away — with a cap of 2 and eight sections, two complete segments, a quarter of the file, per
/// attempt (2026-08-24, against a real FTP server). An endpoint that answers a range request with
/// the whole file is worse still: **every** section downloads the whole thing. Without a latch that
/// price is paid once per file, for every file, on servers where the fast path can never work.
///
/// One instance per **connection**, held by the backend, so it dies with the connection and a
/// reconnect asks again — which is the right expiry for a fact about a server that its
/// administrator can change.
///
/// The rule for setting it is narrower than "the run failed", and the narrowness is the whole point:
/// a total failure says nothing about segmentation — the file may simply not be there — while a run
/// where **some** segments landed and others did not is a server that can serve ranges but not that
/// many at once. Latching on the first is how a missing file would cost every later download its
/// fast path.
public final class SegmentedDownloadSupport: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    public init() {}

    /// Whether this connection has already shown it will not serve a split download.
    public var isRefused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    /// Weigh a segmented run that **failed**, given how many of its pieces the server actually
    /// wrote.
    ///
    /// The rule is *the server served us something and the run still failed*, and it is narrower
    /// than "the run failed" on purpose. Over FTP there is no per-section classification at all —
    /// the reply codes are a race and the exit code is the run's — so this count is the only
    /// evidence available, and it separates the two cases cleanly: a connection cap serves the
    /// sections that fit and refuses the rest, while a missing file or a denied path serves nothing.
    /// Latching on a total failure is how one absent file would cost every later download its fast
    /// path.
    ///
    /// The caller states the evidence rather than its conclusion, which keeps the rule here rather
    /// than in each backend.
    public func recordFailure(served: Int) {
        guard served > 0 else { return }
        lock.lock()
        refused = true
        lock.unlock()
    }

    /// Record that the server answered a range request with something other than the range —
    /// a success that is not what was asked for, and the one refusal that needs no arithmetic.
    public func recordWholeFileAnswer() {
        lock.lock()
        refused = true
        lock.unlock()
    }
}
