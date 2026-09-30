import Testing
@testable import DirnexCore

/// The Bonjour fallback rule (``HostNameFallback``) — every branch driven against a fake resolver,
/// so the one real `getaddrinfo` in the app has nothing left to decide.
///
/// The claims worth stating up front, because they are what the app rests on: a host that works
/// today costs **zero** lookups and comes back byte-identical, a bare label reaches `.local` only
/// after the machine's own resolver has been asked and declined, and a name that resolves nowhere
/// is dialed as typed so the failure names what the user entered.
@Suite("Bonjour host fallback")
struct HostDialingTests {
    // MARK: - Which hosts are even asked about

    @Test("a dotted name and an IP literal are dialed as typed, with nothing resolved")
    func untouchedHosts() {
        for host in [
            "ftp.example.com", "nas.example.com", "192.168.1.3", "10.0.0.1",
            "::1", "fe80::1", "[2001:db8::1]", "[::1]"
        ] {
            #expect(HostNameFallback.candidates(for: host).isEmpty, "\(host) should resolve nothing")
        }
    }

    /// The claim that keeps this feature from costing anything that already works: a host outside
    /// the mDNS family is never resolved, so it cannot be slowed down, redirected, or changed at
    /// all — and it keeps today's "no address family opinion".
    @Test("an untouched host dials exactly as typed and asks for no address family")
    func untouchedHostsDialAsTyped() {
        var asked: [String] = []
        let dialed = HostNameFallback.dial(host: "ftp.example.com") { asked.append($0); return true }
        #expect(dialed == DialedHost.asTyped("ftp.example.com"))
        #expect(dialed.restrictsToIPv4 == false)
        #expect(asked.isEmpty, "an ordinary dotted name must not be resolved at all")
    }

    @Test("a single label offers itself first and the .local completion second")
    func singleLabelCandidates() {
        #expect(HostNameFallback.candidates(for: "nas") == ["nas", "nas.local"])
    }

    @Test("a .local name is resolved but has no further completion to offer")
    func mDNSNameCandidates() {
        #expect(HostNameFallback.candidates(for: "nas.local") == ["nas.local"])
        #expect(HostNameFallback.candidates(for: "NAS.LOCAL") == ["NAS.LOCAL"])
    }

    @Test("an empty or whitespace host resolves nothing")
    func emptyHost() {
        #expect(HostNameFallback.candidates(for: "").isEmpty)
        #expect(HostNameFallback.candidates(for: "   ").isEmpty)
    }

    // MARK: - What gets dialed

    /// The reported bug, end to end: `nas` resolves nowhere, `nas.local` does, so that is what is
    /// dialed — and the address family rides along, which is what stops it costing five seconds a
    /// request.
    @Test("a bare label that resolves nowhere falls back to its .local completion")
    func fallbackToBonjour() {
        var asked: [String] = []
        let dialed = HostNameFallback.dial(host: "nas") {
            asked.append($0)
            return $0 == "nas.local"
        }
        #expect(dialed == DialedHost(host: "nas.local", restrictsToIPv4: true))
        #expect(asked == ["nas", "nas.local"], "the typed name has to be asked first")
    }

    /// The narrowness control for the rule above, and the one that matters most: a machine that
    /// *can* already resolve a bare label — through `/etc/hosts`, or a DNS search domain — keeps
    /// using it, and the `.local` completion is never even asked about. Without this, the fallback
    /// would quietly re-point a working single-label host at a different machine on the LAN.
    @Test("a bare label the machine can already resolve is kept, and .local is never asked")
    func bareLabelThatResolvesIsKept() {
        var asked: [String] = []
        let dialed = HostNameFallback.dial(host: "nas") { asked.append($0); return true }
        #expect(dialed == DialedHost(host: "nas", restrictsToIPv4: true))
        #expect(asked == ["nas"], "a name that resolved must end the search")
    }

    /// A `.local` name typed by the user needs no fallback and still needs the address family — it
    /// is the exact spelling that pays the five seconds, so this is the half that would be lost by
    /// keying the feature on "did we substitute a name".
    @Test("a .local name typed directly is unchanged but still held to IPv4")
    func mDNSNameKeepsItsAddressFamily() {
        let dialed = HostNameFallback.dial(host: "nas.local") { $0 == "nas.local" }
        #expect(dialed == DialedHost(host: "nas.local", restrictsToIPv4: true))
    }

    /// A dead host is dialed as typed rather than as a guess, so the error the user reads names what
    /// they entered — and it carries no address-family claim, because nothing was observed.
    @Test("a host that resolves nowhere is dialed as typed, with no address family claimed")
    func unresolvableHostDialsAsTyped() {
        let dialed = HostNameFallback.dial(host: "nas") { _ in false }
        #expect(dialed == DialedHost.asTyped("nas"))
        #expect(dialed.restrictsToIPv4 == false)
    }

    @Test("an IP literal is never resolved and never restricted")
    func ipLiteralIsUntouched() {
        var asked: [String] = []
        let dialed = HostNameFallback.dial(host: "192.168.1.3") { asked.append($0); return true }
        #expect(dialed == DialedHost.asTyped("192.168.1.3"))
        #expect(asked.isEmpty)
    }

    // MARK: - Edges

    @Test("a trailing dot is a spelling, not a second label")
    func trailingDot() {
        #expect(HostNameFallback.candidates(for: "nas.") == ["nas.", "nas.local"])
        #expect(HostNameFallback.candidates(for: "nas.local.") == ["nas.local."])
        #expect(HostNameFallback.candidates(for: ".").isEmpty)
    }

    /// `local` is a legal single-label host name and is not an mDNS name, so it takes the ordinary
    /// fallback rather than being mistaken for one that already carries the suffix.
    @Test("a host actually named local is an ordinary single label")
    func hostNamedLocal() {
        #expect(HostNameFallback.candidates(for: "local") == ["local", "local.local"])
    }

    @Test("IP literal detection covers both families and the bracketed spelling")
    func ipLiteralDetection() {
        #expect(HostNameFallback.isIPLiteral("192.168.1.3"))
        #expect(HostNameFallback.isIPLiteral("::1"))
        #expect(HostNameFallback.isIPLiteral("[2001:db8::1]"))
        #expect(!HostNameFallback.isIPLiteral("nas"))
        #expect(!HostNameFallback.isIPLiteral("nas.local"))
        // A name that merely looks numeric is still a name.
        #expect(!HostNameFallback.isIPLiteral("192.168.1"))
    }
}
