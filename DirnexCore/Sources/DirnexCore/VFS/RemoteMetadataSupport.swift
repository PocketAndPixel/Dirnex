import Foundation

/// What one connection has so far failed to carry, and over how many items.
///
/// Aggregated rather than per file, because the fact is a property of the **server**: either an
/// account honours `SITE CHMOD` or it does not, and a user reading a report wants one sentence
/// rather than three thousand identical rows. The count is what makes that sentence honest — it
/// says how much was affected without claiming every file was.
public struct RemoteMetadataLoss: Sendable, Hashable {
    /// What could not be carried. Never empty — a loss with nothing in it is not a loss, which is
    /// why ``RemoteMetadataSupport/loss`` answers `nil` instead.
    public let aspects: Set<RemoteMetadataAspect>
    /// How many items lost at least one of them.
    public let itemCount: Int

    public init(aspects: Set<RemoteMetadataAspect>, itemCount: Int) {
        self.aspects = aspects
        self.itemCount = itemCount
    }
}

/// Remembers what one connection's server will not do about metadata, so the next file does not pay
/// to find out again — and remembers what that cost, so the app can *say* what a copy could not keep.
///
/// One instance per **connection**, held by the backend, so it dies with the connection and a
/// reconnect asks again: the right expiry for a fact about a server that its administrator can
/// change. That is ``SegmentedDownloadSupport``'s shape exactly, and for the same reason — none of
/// these capabilities can be queried in advance, so the only way to learn one is to attempt the verb
/// and read the refusal (PLAN.md §M25: degrade per connection at run time).
///
/// **The rule for latching is narrower than "the step failed", and the narrowness is the whole
/// point.** Measured 2026-08-28 against a real FTP server, a refused quote command answers with the
/// reply code that separates the two cases: **500** is *this server does not implement the verb*,
/// which is true of every file and worth remembering, while **550** is *that file's problem*, which
/// says nothing about the server. Latching on the second is how one unwritable file would cost every
/// later copy its mode. The SFTP side has the same split — a `chmod` refused
/// `remote setstat "…": Permission denied` is about the file, not the account.
///
/// So callers state the **evidence** and the rule lives here, which is what keeps it in one place
/// rather than in each backend.
public final class RemoteMetadataSupport: @unchecked Sendable {
    private let lock = NSLock()
    /// What the transport declared it can do at all — the ceiling this connection starts from.
    private let offered: RemoteMetadataCapabilities
    private var refused: RemoteMetadataCapabilities = []
    private var lostAspects: Set<RemoteMetadataAspect> = []
    private var affectedItems = 0

    /// - Parameter offering: what this transport can be asked to do before anything has been
    ///   refused — ``RemoteMetadataCapabilities/sftp`` or ``RemoteMetadataCapabilities/ftp`` for the
    ///   shipped transports, and `[]` for one that has not implemented the carry at all. An empty
    ///   set is the safe default rather than a broken one: every plan then carries nothing and
    ///   *reports* the loss, which is the failure direction this milestone exists to choose.
    public init(offering: RemoteMetadataCapabilities) {
        offered = offering
    }

    /// What may still be attempted on this connection: what the transport offers, less whatever the
    /// server has since refused as unimplemented.
    public var capabilities: RemoteMetadataCapabilities {
        lock.lock()
        defer { lock.unlock() }
        return offered.subtracting(refused)
    }

    /// The plan for carrying `source`, against what this connection can still be asked to do.
    ///
    /// Reading the capabilities and building the plan in one call is deliberate: two calls would let
    /// a refusal land between them, and the plan would then name a step the connection has just
    /// learned it cannot take.
    public func plan(for source: RemoteSourceMetadata) -> RemoteMetadataPlan {
        source.plan(with: capabilities)
    }

    /// The plan for carrying `source` where there is **no transfer verb to ride on** — a directory
    /// the engine recreated by hand, or a server-side `cp`.
    ///
    /// The preserve flag belongs to `get`/`put` and to nothing else, so a route without one has to
    /// subtract it or the plan claims a carry that has no mechanism. Its own method rather than the
    /// subtraction written out at each site, because the two callers cannot see each other and the
    /// consequence of one of them forgetting is a copy that reports a modification time it never
    /// wrote — this milestone's whole subject.
    public func planWithoutTransferFlag(for source: RemoteSourceMetadata) -> RemoteMetadataPlan {
        source.plan(with: capabilities.subtracting(.preserveFlag))
    }

    /// Record that the server answered **"I do not implement that verb"** — FTP's reply **500**, the
    /// one refusal that is a fact about the account rather than about a file.
    ///
    /// Latches, so no later transfer on this connection attempts it, and counts the aspects that
    /// step would have carried as lost.
    public func recordUnsupported(_ capability: RemoteMetadataCapabilities) {
        lock.lock()
        refused.formUnion(capability)
        lock.unlock()
    }

    /// Record what one item's transfer could not carry — whether the plan said so up front or a
    /// step was refused after the fact.
    ///
    /// Does **not** latch: a step refused for one file (FTP's 550, `sftp`'s
    /// `remote setstat "…": Permission denied`) says nothing about the next one. Empty is ignored,
    /// so the ordinary complete transfer costs nothing and never inflates the count.
    public func record(dropped: Set<RemoteMetadataAspect>) {
        guard !dropped.isEmpty else { return }
        lock.lock()
        lostAspects.formUnion(dropped)
        affectedItems += 1
        lock.unlock()
    }

    /// What this connection has failed to carry so far, or `nil` when it has carried everything it
    /// was asked to — which is the good case and the common one.
    ///
    /// **Nothing on screen reads this yet**, and saying so is part of the design rather than a
    /// caveat: the accumulator is what makes a loss *knowable*, and choosing where a user is told
    /// about it — a status line, the operation report, Get Info — is its own decision (PLAN.md §M25
    /// Slice 5). What it must not become meanwhile is a value justified by a reader that does not
    /// exist, so it is deliberately the smallest thing the tests can hold: aspects and a count.
    /// A draining `takeLoss()` was written alongside it and deleted for exactly that reason — the
    /// run boundary it existed to mark belongs to whoever ends up doing the reporting.
    public var loss: RemoteMetadataLoss? {
        lock.lock()
        defer { lock.unlock() }
        guard !lostAspects.isEmpty else { return nil }
        return RemoteMetadataLoss(aspects: lostAspects, itemCount: affectedItems)
    }
}
