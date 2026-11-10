import Foundation

/// The space a server says it has left, for the tooltip on its saved sidebar row (PLAN.md §M38
/// Slice 7, and its SFTP follow-up of 2026-11-11).
///
/// Two protocols answer, and they answer different questions, which is what ``totalBytes`` keeps:
///
/// - **WebDAV** reports what is left to the *account* (RFC 4331, ``WebDAVQuota``) and no total worth
///   showing, because what Nextcloud reports as used is the folder's and not the account's.
/// - **SFTP** reports the *filesystem* holding the login directory (OpenSSH's `statvfs` extension,
///   ``SFTPDiskFree``): the same numbers a local volume's row shows, total included.
public struct ServerSpace: Sendable, Equatable {
    /// Bytes the server will still store for this account.
    public let availableBytes: Int64
    /// The size of what ``availableBytes`` is a part of, or `nil` when the server gives no total that
    /// means anything.
    public let totalBytes: Int64?

    public init(availableBytes: Int64, totalBytes: Int64? = nil) {
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    /// A WebDAV server's quota, which has no total (``WebDAVProcessArguments/quotaPropfindBody``).
    public init(_ quota: WebDAVQuota) {
        self.init(availableBytes: quota.availableBytes)
    }

    /// How long an answer stands before a listing on the same connection asks again: five minutes.
    ///
    /// The number is WebDAV's, where it is how long Nextcloud keeps its own answer. Measured
    /// 2026-11-10: with the quota changed and two files uploaded, the answer stayed exactly as it
    /// was for five minutes and then showed both, so asking sooner there costs a request and learns
    /// nothing. An SFTP server's answer is live (a 10 MiB `put` showed at once, 2026-11-11), so there
    /// the rule is the cost instead: each ask is one more `sftp` session, a connect, key exchange
    /// and login, and a tooltip does not need to follow a copy to the byte.
    public static let refreshInterval: TimeInterval = 300

    /// Whether a listing that arrived at `now` should ask again, the last ask having gone out at
    /// `lastAsked`. A clock that has gone backwards is due, so a corrected clock cannot hold an old
    /// answer for as long as it moved.
    public static func isDue(lastAsked: Date?, now: Date) -> Bool {
        guard let lastAsked else { return true }
        let elapsed = now.timeIntervalSince(lastAsked)
        return elapsed < 0 || elapsed >= refreshInterval
    }
}

/// A server that cannot report its space at all, as against one that reports none at the moment.
///
/// Thrown, not answered, because the caller treats it differently from both: an answer replaces the
/// last one, a failure leaves it standing, and this is a fact about the server that holds for the
/// rest of the launch, so the server is not asked again. The one case today is an SFTP server
/// without OpenSSH's `statvfs` extension (``SFTPDiskFree/space(in:)``).
public struct ServerSpaceUnsupported: Error, Equatable {
    public init() {}
}
