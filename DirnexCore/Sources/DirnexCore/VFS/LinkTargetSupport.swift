import Foundation

/// Remembers that one connection has no exec channel to read a symlink's target with, so the next
/// link does not pay to find out again (PLAN.md §M25 Slice 4).
///
/// The shape is ``ServerSideCopySupport``'s and ``SegmentedDownloadSupport``'s, and for the same
/// reason: nothing can be asked in advance. An account confined to the `sftp` subsystem
/// (`ForceCommand internal-sftp`) browses and transfers perfectly and simply answers an exec request
/// with prose — so the only way to learn is to send the command and read what comes back, and the
/// only sensible expiry is the connection, since an administrator can change it.
///
/// **What a latch saves here is a whole connection per batch of links.** Measured 2026-08-28 against
/// a loopback `sshd`: one exec is 77 ms whatever it is asked, so a tree carrying links in twenty
/// directories would otherwise spend twenty handshakes being told the same thing before refusing
/// each one anyway.
///
/// **The rule for latching is "no answer at all", never "no target for this path"**, and the
/// narrowness is the whole point — the same split ``ServerSideCopySupport`` draws. A batch that
/// comes back with rows, of which one path is missing or turns out not to be a link, has told us
/// about *those paths*: the channel is there and working. Only output that carries no recognisable
/// row is evidence about the **account**, and it is exactly what an `sftp`-only one produces
/// (measured: *"This service allows sftp connections only."* on stdout, with no exit status to tell
/// it apart — see ``SSHLinkTargetParser``).
public final class LinkTargetSupport: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    public init() {}

    /// Whether this connection has already shown it cannot answer what a link points at.
    public var isRefused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    /// Record that a read came back without a single row this command could have produced — the one
    /// outcome that is about the account rather than about the paths asked for.
    public func recordUnavailable() {
        lock.lock()
        refused = true
        lock.unlock()
    }
}
