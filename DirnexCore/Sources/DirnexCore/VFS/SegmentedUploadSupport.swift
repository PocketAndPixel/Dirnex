import Foundation

/// Remembers whether one connection's account has the exec channel a segmented upload needs, so the
/// next file does not pay to find out again.
///
/// **The cost this avoids is the whole upload.** A segmented download that turns out to be
/// unavailable wastes a download; here the parts are sent *first* and only the join needs the exec
/// channel, so discovering the refusal afterwards would mean the file crossed the network and was
/// then thrown away. That is why the question is asked **up front** with a sentinel echo — 64 ms
/// against a real `sshd`, once per connection — rather than found out by trying.
///
/// One instance per **connection**, held by the backend, so it dies with the connection and a
/// reconnect asks again — the right expiry for a fact about a server its administrator can change
/// (`ForceCommand internal-sftp` is one line of `sshd_config`).
///
/// **Deliberately not shared with ``SegmentedDownloadSupport``**, though a connection with no exec
/// channel can serve neither. That latch answers a wider question — its rule is "the server served
/// some pieces and the run still failed", which also catches a cap on concurrent connections — and
/// folding the two would let a *download* refused for running out of connections withdraw the
/// upload's route, or an upload's clean answer re-permit a download the server had already refused.
/// One probe per connection is cheaper than either mistake.
public final class SegmentedUploadSupport: @unchecked Sendable {
    private let lock = NSLock()
    private var execChannel: Bool?

    public init() {}

    /// Whether this connection has already shown it cannot join parts on the server.
    public var isRefused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return execChannel == false
    }

    /// Whether the question has been put to this account at all.
    ///
    /// Read so the probe is sent once rather than before every file: an answer of either kind is
    /// final for the life of the connection.
    public var hasAsked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return execChannel != nil
    }

    /// Record what the account answered — the probe's verdict, or a join that came back as
    /// something other than a byte count, which is the same fact discovered later.
    public func record(execChannel available: Bool) {
        lock.lock()
        execChannel = available
        lock.unlock()
    }
}
