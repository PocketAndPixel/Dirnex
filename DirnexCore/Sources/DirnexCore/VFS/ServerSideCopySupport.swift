import Foundation

/// Remembers that one connection's server will not duplicate a file for us, so the next copy does
/// not pay to find out again.
///
/// The verb is OpenSSH's `copy-data` extension (`sftp`'s `cp`), and like every other capability this
/// milestone reaches for it cannot be queried in advance: the client checks what the server
/// advertised and refuses on its own, which from a transport's side is indistinguishable from any
/// other failed command until the sentence is read. So the shape is M22's — attempt the verb, read
/// the refusal, remember it for that connection — and one instance lives on the backend, dying with
/// the connection so a reconnect asks again. That is the right expiry for a fact about a server
/// whose administrator can change it.
///
/// **The cost a latch avoids here is a round trip per file, not bytes**, which is the difference
/// from ``SegmentedDownloadSupport``: a refused `cp` transfers nothing and creates nothing
/// (measured 2026-08-28 against a server started with `sftp-server -P copy-data`, which is how an
/// old or restricted server behaves). Every copy on such an account would otherwise spend a whole
/// TCP connect, key exchange and authentication — 71 ms on loopback — to be told the same thing
/// before falling back to ``RelayCopy``.
///
/// **The rule for latching is narrower than "the copy failed", and the narrowness is the whole
/// point.** `Server does not support copy-data extension` is a fact about the account and is true
/// of every file; `stat remote: No such file or directory` and `Cannot copy non-regular file: …`
/// are facts about the operands and say nothing about the server. Latching on the second is how one
/// missing file would cost every later copy its fast path — the same split
/// ``RemoteMetadataRefusal`` draws for a refused `chmod`, which is why callers state the evidence
/// and the rule lives here.
public final class ServerSideCopySupport: @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    public init() {}

    /// Whether this connection has already shown it cannot copy a file server-side.
    public var isRefused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    /// Record that the client reported the server does not offer the copy extension — the one
    /// refusal that is about the account rather than about the two paths.
    public func recordUnsupported() {
        lock.lock()
        refused = true
        lock.unlock()
    }
}
