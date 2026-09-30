import DirnexCore
import Foundation

/// Resolves a connection's dial name **once** and remembers it for that connection's lifetime — the
/// non-hermetic half of ``HostNameFallback``, which owns every rule and is tested against a fake.
///
/// **Why the transport and not the connect flow.** Registering a connection is documented as costing
/// no round trip, which is what lets session restore run synchronously on the main actor at launch,
/// and resolution is not free in the case that matters: measured 2026-09-04, a `.local` name that is
/// *absent* costs **5.003 s**, because mDNS has no negative answer and the query waits out its
/// timeout. Putting that in `connectFTP` would block launch for five seconds whenever a saved NAS
/// happened to be switched off. Here it is paid inside the first verb, which is already a network
/// round trip and already runs off the main actor, and every later verb reads the cache.
///
/// **Why the result is cached even when it fails.** A failure means "dial what the user typed", and
/// re-deriving that per verb would pay the 5 s again on every request to a server that is down —
/// doubling what the transport's own `curl` or `ssh` is about to spend anyway. Caching it costs
/// nothing that heals: a host typed as `nas.local` is dialed as `nas.local` and re-resolved by the
/// tool itself on every invocation, so a NAS that comes back is picked up with no reconnect. Only a
/// bare label that resolved nowhere stays unresolved for the connection's life, and that connection
/// never worked in the first place.
final class HostDialer: @unchecked Sendable {
    private let host: String
    private let resolvesIPv4: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var cached: DialedHost?

    /// `resolvesIPv4` is injected so a test can drive every branch without a network, and defaults
    /// to the real `getaddrinfo`.
    init(
        host: String,
        resolvesIPv4: @escaping @Sendable (String) -> Bool = HostDialer.systemResolvesIPv4
    ) {
        self.host = host
        self.resolvesIPv4 = resolvesIPv4
    }

    /// The name to dial and the address family to ask for, resolved on first use.
    var dialed: DialedHost {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let resolved = HostNameFallback.dial(host: host, resolvesIPv4: resolvesIPv4)
        cached = resolved
        return resolved
    }

    /// Whether `host` has an IPv4 address, asked of the system resolver.
    ///
    /// **`AF_INET` only, and that is the whole point.** An unspecified-family lookup waits for both
    /// records, and on an mDNS name the AAAA never arrives — measured, `getaddrinfo("nas.local")`
    /// takes 10.85 s unspecified against 0.010 s for `AF_INET` alone. Asking the one question whose
    /// answer decides the matter is what keeps this cheap enough to sit in front of a listing.
    static func systemResolvesIPv4(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        if let result { freeaddrinfo(result) }
        return status == 0
    }
}
