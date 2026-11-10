import DirnexCore
import Foundation

/// What each saved server last said about the space it has left, for the tooltip on its sidebar row
/// (PLAN.md §M38 Slice 7, ``ServerSpace``): a WebDAV server's quota (``WebDAVQuota``), and since
/// 2026-11-11 an SFTP server's filesystem (``SFTPDiskFree``).
///
/// When it asks was Oleg's call (2026-11-10), and SFTP follows it: **after a listing on the
/// connection has arrived, at most once every five minutes** (``ServerSpace/isDue(lastAsked:now:)``).
/// After a listing, never before one, because a listing that arrived has proved the password: asked
/// beside a reconnect's first listing, a wrong password would cost two failed logins where it cost
/// one, and the NAS locks an account after a few. And only then, so with Settings' refresh floor at 0
/// nothing is asked that the user did not ask for. Every pane's listing passes here, the background
/// refresh's included, so an idle pane on a server asks once every five minutes and a pane on
/// nothing asks nothing.
///
/// A server that cannot say at all (``ServerSpaceUnsupported``, an SFTP server without the
/// `statvfs` extension) is not asked again until the app is relaunched, since each ask is a whole
/// session there and the answer would not change.
///
/// Keyed by the server's location, which a saved server row and the pane it opened share, so two
/// panes on one account ask once between them. Main actor only, and the request goes off it.
@MainActor
final class ServerQuotaBook {
    static let shared = ServerQuotaBook()

    /// Posted when a server's answer changes, so open sidebars redraw its row's tooltip. The object
    /// is the book, and there is no payload: observers read ``space(for:)``.
    static let didChangeNotification = Notification.Name("Dirnex.serverQuotaDidChange")

    /// A server the book keeps an answer for: the location a saved row and its pane share.
    enum Server: Hashable {
        case webDAV(WebDAVLocation)
        case sftp(SFTPLocation)

        /// The server a saved row's endpoint names, or `nil` for a protocol that is never asked.
        init?(_ endpoint: ServerEndpoint) {
            switch endpoint {
            case let .webdav(location, _, _): self = .webDAV(location)
            case let .sftp(location, _): self = .sftp(location)
            case .ftp, .smb, .s3, .s3Account: return nil
            }
        }
    }

    private struct Entry {
        var space: ServerSpace?
        var lastAsked: Date?
        var isAsking = false
        var cannotSay = false
    }

    private var entries: [Server: Entry] = [:]
    private let clock: () -> Date

    /// `clock` is injectable so a test can step past the five minutes without waiting them out.
    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// The space `server` last said it has left, or `nil` when it has said none, or has not been
    /// asked.
    func space(for server: Server) -> ServerSpace? {
        entries[server]?.space
    }

    /// A listing on `backend`'s connection arrived: ask its root for the space left, if the last
    /// answer is old enough.
    func listingArrived(on backend: WebDAVBackend) {
        listingArrived(at: .webDAV(backend.location)) { try backend.quota().map(ServerSpace.init) }
    }

    /// A listing on `backend`'s connection arrived: ask the filesystem under its login directory,
    /// if the last answer is old enough.
    func listingArrived(on backend: SFTPBackend) {
        listingArrived(at: .sftp(backend.location)) { try backend.space() }
    }

    /// The same with the question handed in, which is how a test watches the schedule without a
    /// server. Answers the request's task, or `nil` when nothing was asked: one already in flight
    /// for this server, an answer younger than five minutes, or a server that cannot say.
    @discardableResult
    func listingArrived(
        at server: Server,
        asking question: @escaping @Sendable () throws -> ServerSpace?
    ) -> Task<Void, Never>? {
        var entry = entries[server] ?? Entry()
        let now = clock()
        guard !entry.isAsking, !entry.cannotSay,
              ServerSpace.isDue(lastAsked: entry.lastAsked, now: now)
        else { return nil }
        entry.lastAsked = now
        entry.isAsking = true
        entries[server] = entry
        return Task { @MainActor in
            let answer = await BlockingWork.run(qos: .utility) { Result { try question() } }
            settle(answer, for: server)
        }
    }

    /// Keep what the server answered. A request that got no answer says nothing about the server, so
    /// the last answer stands; an answer with no space in it clears one, since the server no longer
    /// reports it, and so does a server that cannot say, which is then not asked again.
    private func settle(_ answer: Result<ServerSpace?, any Error>, for server: Server) {
        guard var entry = entries[server] else { return }
        entry.isAsking = false
        let reported: ServerSpace?
        switch answer {
        case let .success(space):
            reported = space
        case let .failure(error) where error is ServerSpaceUnsupported:
            entry.cannotSay = true
            reported = nil
        case .failure:
            entries[server] = entry
            return
        }
        let changed = reported != entry.space
        entry.space = reported
        entries[server] = entry
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

extension PanelViewController {
    /// A listing arrived from a server: if it is a WebDAV or SFTP one this pane is connected to, it
    /// may ask for the space left (``ServerQuotaBook``).
    func askServerQuota(after path: VFSPath) {
        guard let composite = backend as? CompositeBackend else { return }
        if let webDAV = composite.webDAVBackend(for: path.backend) {
            ServerQuotaBook.shared.listingArrived(on: webDAV)
        } else if let sftp = composite.sftpBackend(for: path.backend) {
            ServerQuotaBook.shared.listingArrived(on: sftp)
        }
    }
}
