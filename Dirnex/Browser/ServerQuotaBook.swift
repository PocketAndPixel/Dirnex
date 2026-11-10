import DirnexCore
import Foundation

/// What each WebDAV server last said about the space it has left, for the tooltip on its sidebar row
/// (PLAN.md §M38 Slice 7, ``WebDAVQuota``).
///
/// When it asks was Oleg's call (2026-11-10): **after a listing on the connection has arrived, at
/// most once every five minutes** (``WebDAVQuota/isDue(lastAsked:now:)``). After a listing, never
/// before one, because a listing that arrived has proved the password: asked beside a reconnect's
/// first listing, a wrong password would cost two failed logins where it cost one, and the NAS locks
/// an account after a few. And only then, so with Settings' refresh floor at 0 nothing is asked that
/// the user did not ask for. Every pane's listing passes here, the background refresh's included, so
/// an idle pane on a server asks once every five minutes and a pane on nothing asks nothing.
///
/// Keyed by ``WebDAVLocation``, which a saved server row and the pane it opened share, so two panes
/// on one account ask once between them. Main actor only, and the request goes off it.
@MainActor
final class ServerQuotaBook {
    static let shared = ServerQuotaBook()

    /// Posted when a server's answer changes, so open sidebars redraw its row's tooltip. The object
    /// is the book, and there is no payload: observers read ``quota(for:)``.
    static let didChangeNotification = Notification.Name("Dirnex.serverQuotaDidChange")

    private struct Entry {
        var quota: WebDAVQuota?
        var lastAsked: Date?
        var isAsking = false
    }

    private var entries: [WebDAVLocation: Entry] = [:]
    private let clock: () -> Date

    /// `clock` is injectable so a test can step past the five minutes without waiting them out.
    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// The space `location`'s server last said it has left, or `nil` when it has said none, or has
    /// not been asked.
    func quota(for location: WebDAVLocation) -> WebDAVQuota? {
        entries[location]?.quota
    }

    /// A listing on `backend`'s connection arrived: ask its root for the space left, if the last
    /// answer is old enough.
    func listingArrived(on backend: WebDAVBackend) {
        listingArrived(at: backend.location) { try backend.quota() }
    }

    /// The same with the question handed in, which is how a test watches the schedule without a
    /// server. Answers the request's task, or `nil` when nothing was asked: one already in flight
    /// for this server, or an answer younger than five minutes.
    @discardableResult
    func listingArrived(
        at location: WebDAVLocation,
        asking question: @escaping @Sendable () throws -> WebDAVQuota?
    ) -> Task<Void, Never>? {
        var entry = entries[location] ?? Entry()
        let now = clock()
        guard !entry.isAsking, WebDAVQuota.isDue(lastAsked: entry.lastAsked, now: now) else {
            return nil
        }
        entry.lastAsked = now
        entry.isAsking = true
        entries[location] = entry
        return Task { @MainActor in
            let answer = await BlockingWork.run(qos: .utility) { Result { try question() } }
            settle(answer, for: location)
        }
    }

    /// Keep what the server answered. A request that got no answer says nothing about the server, so
    /// the last answer stands; an answer with no quota in it clears one, since the server no longer
    /// reports it.
    private func settle(_ answer: Result<WebDAVQuota?, any Error>, for location: WebDAVLocation) {
        guard var entry = entries[location] else { return }
        entry.isAsking = false
        let changed: Bool
        if case let .success(quota) = answer, quota != entry.quota {
            entry.quota = quota
            changed = true
        } else {
            changed = false
        }
        entries[location] = entry
        if changed {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

extension PanelViewController {
    /// A listing arrived from a server: if it is a WebDAV one this pane is connected to, it may ask
    /// for the space left (``ServerQuotaBook``).
    func askServerQuota(after path: VFSPath) {
        guard let composite = backend as? CompositeBackend,
              let webDAV = composite.webDAVBackend(for: path.backend)
        else { return }
        ServerQuotaBook.shared.listingArrived(on: webDAV)
    }
}
