import Foundation

/// Which name a transport actually dials for the host a user typed, and whether to hold the lookup
/// to IPv4.
///
/// The two travel together because they are decided together: the address family is not a policy
/// anybody set, it is a *record of what the resolution found*. A name that answered on IPv4 is dialed
/// on IPv4, which costs nothing to say and saves a query that provably never answers (see
/// ``HostNameFallback``).
public struct DialedHost: Sendable, Hashable {
    /// The name to put in a `curl` URL or an `ssh` target — the host as typed, unless a fallback
    /// resolved where it did not.
    public let host: String
    /// Whether the transport should ask for IPv4 only (`curl -4`, `ssh -o AddressFamily=inet`).
    ///
    /// Never a downgrade: it is set only once an IPv4 address has been *observed* for ``host``, so
    /// it withholds a query whose answer is already known rather than a route that might have
    /// worked.
    public let restrictsToIPv4: Bool

    public init(host: String, restrictsToIPv4: Bool) {
        self.host = host
        self.restrictsToIPv4 = restrictsToIPv4
    }

    /// Dial exactly what the user typed, with no address-family opinion — today's behaviour, and
    /// what every host outside the mDNS family gets without a single syscall being spent.
    public static func asTyped(_ host: String) -> DialedHost {
        DialedHost(host: host, restrictsToIPv4: false)
    }
}

/// The Bonjour fallback that lets a bare LAN name like `nas` reach a server, and the address-family
/// record that keeps an mDNS name from costing five seconds a request.
///
/// **Why it is needed at all:** `smb://nas` works and `ftp://nas` does not, and the two do not share
/// a resolver. Dirnex mounts SMB through `NetFSMountURLSync`, and Apple's SMB stack carries NetBIOS
/// name resolution of its own — `smbutil lookup nas` answers off a broadcast. `curl` and `ssh` have
/// only the system resolver, and with no DNS search domain configured a single-label name has
/// nothing to be completed with: measured 2026-09-04, `getaddrinfo("nas")` fails in **0.003 s** for
/// every address family, and `curl ftp://nas/` exits 6. The general macOS way to name that machine
/// is Bonjour, and `nas.local` resolves fine — so a single label that resolves nowhere is retried
/// with `.local` appended, which is the completion the user's own network already answers.
///
/// **Why the address family rides along:** an mDNS name has no negative answer, so a query for a
/// record the host does not publish waits out its full timeout. Measured against a NAS that
/// publishes no IPv6, on a Mac with no global IPv6 address at all:
///
/// | lookup | time |
/// |---|---|
/// | `nas.local`, both families | 5.005 / 5.007 / 5.008 s |
/// | `nas.local`, IPv4 only | 0.003 s (5 runs) |
/// | `example.com`, both families | 0.307 s |
///
/// `AI_ADDRCONFIG` does **not** dodge it (5.004 s). The `example.com` row is the control: the stall
/// is mDNS's, not hostname resolution's in general, which is why nothing outside this family is
/// touched. `ssh` pays it identically — 5.07 s against 0.05 s with `-4` — so both transports carry
/// the same record, spelled `-4` for `curl` and `AddressFamily=inet` for `ssh`.
///
/// It is pure: the caller supplies the resolution as a closure, so every rule here is tested against
/// a fake and the one `getaddrinfo` lives in the app beside the subprocess it serves.
public enum HostNameFallback {
    /// The suffix Bonjour answers for.
    public static let mDNSSuffix = ".local"

    /// The names to try for `host`, in order — or an **empty** list when it must be dialed exactly
    /// as typed, resolving nothing.
    ///
    /// Empty is the answer for the overwhelmingly common cases, and that is the point: an IP literal
    /// and an ordinary dotted name each cost zero syscalls, so nothing that works today pays for
    /// this or can be changed by it. Only two shapes resolve — a single label (which may need the
    /// fallback) and a name already ending in `.local` (which needs no fallback but does need the
    /// address-family record, since it is the spelling that pays the five seconds).
    public static func candidates(for host: String) -> [String] {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isIPLiteral(trimmed) else { return [] }
        // A trailing dot is a fully-qualified name's own spelling. It is dropped for the shape
        // questions below and kept in what is dialed, which is what the user typed.
        let bare = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        guard !bare.isEmpty else { return [] }
        if bare.lowercased().hasSuffix(mDNSSuffix) { return [trimmed] }
        guard !bare.contains(".") else { return [] }
        return [trimmed, bare + mDNSSuffix]
    }

    /// The name to dial for `host`, given a way to ask whether a name has an IPv4 address.
    ///
    /// The first candidate that resolves wins, so a single label that the machine *can* already
    /// resolve — through `/etc/hosts`, or a DNS search domain — keeps working exactly as it does
    /// now and never reaches the `.local` fallback. A host that resolves nowhere is dialed as typed
    /// so the failure the user reads names what they entered.
    public static func dial(host: String, resolvesIPv4: (String) -> Bool) -> DialedHost {
        let candidates = candidates(for: host)
        guard !candidates.isEmpty else { return .asTyped(host) }
        for candidate in candidates where resolvesIPv4(candidate) {
            return DialedHost(host: candidate, restrictsToIPv4: true)
        }
        return .asTyped(host)
    }

    /// Whether `host` is a numeric address rather than a name — including a bracketed IPv6 literal,
    /// the spelling a URL uses.
    static func isIPLiteral(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        guard !bare.isEmpty else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, bare, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, bare, &v6) == 1
    }
}
