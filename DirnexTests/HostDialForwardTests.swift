import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// That the Bonjour fallback is actually *wired* — the half no headless rule can assert for itself,
/// and the one this codebase keeps paying for.
///
/// ``HostNameFallback`` is fully covered in the core, so what is left here is the forward: does the
/// transport that spawns `curl` and `ssh` ask it, and does the answer reach the argv? A wiring that
/// quietly kept the location's own host would leave every core test green, both linters clean, and
/// the feature simply absent — the shape docs/NOTES.md records for `subtreeListing` and
/// `metadataTally`. Each claim is paired with the control that a host outside the mDNS family is
/// dialed byte-identically to how it is today.
@Suite("Bonjour fallback is wired into the transports")
struct HostDialForwardTests {
    private static let ftp = FTPLocation(
        host: "nas", port: 21, username: "dirnex-test", security: .plain
    )
    private static let sftp = SFTPLocation(host: "nas", port: 22, username: "dirnex-test")

    /// A resolver that answers for `nas.local` and nothing else — the measured shape of the machine
    /// this was reported on.
    private static func bonjourOnly(_ counter: Counter? = nil) -> @Sendable (String) -> Bool {
        { host in
            counter?.bump(host)
            return host == "nas.local"
        }
    }

    /// Counts what the resolver was asked, so "resolved once" and "never resolved" are assertions
    /// rather than hopes.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        func bump(_ host: String) { lock.lock(); asked.append(host); lock.unlock() }
        var questions: [String] { lock.lock(); defer { lock.unlock() }; return asked }
    }

    // MARK: - The dialer itself

    /// The whole reason the dialer is a reference type: an absent `.local` name costs five seconds
    /// to resolve, and every FTP verb is a fresh `curl`. Paying that once per connection is the
    /// design; paying it per request would be worse than the bug.
    @Test("the dial is resolved once and reused")
    func resolvesOncePerConnection() {
        let counter = Counter()
        let dialer = HostDialer(host: "nas", resolvesIPv4: Self.bonjourOnly(counter))
        #expect(dialer.dialed == DialedHost(host: "nas.local", restrictsToIPv4: true))
        #expect(dialer.dialed == DialedHost(host: "nas.local", restrictsToIPv4: true))
        #expect(dialer.dialed.host == "nas.local")
        #expect(counter.questions == ["nas", "nas.local"], "resolution must happen exactly once")
    }

    /// The control that keeps this feature free for everyone it does not serve: an ordinary dotted
    /// host is never resolved, so it cannot be slowed down or re-pointed.
    @Test("a dotted host is never resolved at all")
    func dottedHostCostsNothing() {
        let counter = Counter()
        let dialer = HostDialer(host: "ftp.example.com", resolvesIPv4: Self.bonjourOnly(counter))
        #expect(dialer.dialed == DialedHost.asTyped("ftp.example.com"))
        #expect(counter.questions.isEmpty)
    }

    /// The real `getaddrinfo` wrapper, which nothing else in either suite exercises. `localhost` is
    /// answered from `/etc/hosts` on every Mac, so this needs no network and cannot flake on one.
    @Test("the system resolver answers for a name that exists and declines one that does not")
    func systemResolver() {
        #expect(HostDialer.systemResolvesIPv4("localhost"))
        #expect(HostDialer.systemResolvesIPv4("127.0.0.1"))
        #expect(!HostDialer.systemResolvesIPv4("dirnex-no-such-host-8f3a1c"))
    }

    // MARK: - The forward

    @Test("the FTP transport dials the fallback host and asks curl for IPv4")
    func ftpTransportForwardsTheDial() {
        let transport = FTPCurlTransport(
            location: Self.ftp,
            authentication: .password,
            dialer: HostDialer(host: Self.ftp.host, resolvesIPv4: Self.bonjourOnly())
        )
        #expect(transport.session.dial == DialedHost(host: "nas.local", restrictsToIPv4: true))
        let arguments = FTPProcessArguments.list(session: transport.session, remotePath: "/")
        #expect(arguments.contains("ftp://nas.local:21/"))
        #expect(arguments.contains("-4"))
    }

    @Test("an FTP host that needs no fallback is dialed exactly as typed")
    func ftpTransportControl() {
        let location = FTPLocation(
            host: "ftp.example.com", port: 21, username: "dirnex-test", security: .plain
        )
        let transport = FTPCurlTransport(
            location: location,
            authentication: .password,
            dialer: HostDialer(host: location.host, resolvesIPv4: Self.bonjourOnly())
        )
        let arguments = FTPProcessArguments.list(session: transport.session, remotePath: "/")
        #expect(arguments.contains("ftp://ftp.example.com:21/"))
        #expect(!arguments.contains("-4"))
    }

    @Test("the SFTP transport dials the fallback host on both of its channels")
    func sftpTransportForwardsTheDial() {
        let transport = SFTPProcessTransport(
            location: Self.sftp,
            authentication: .key(identityFile: "/k"),
            dialer: HostDialer(host: Self.sftp.host, resolvesIPv4: Self.bonjourOnly())
        )
        for arguments in [transport.batchArguments, transport.execArguments(command: "true")] {
            #expect(arguments.contains("dirnex-test@nas.local"))
            #expect(arguments.contains("AddressFamily=inet"))
        }
    }

    @Test("an SFTP host that needs no fallback is dialed exactly as typed")
    func sftpTransportControl() {
        let location = SFTPLocation(host: "sftp.example.com", port: 22, username: "dirnex-test")
        let transport = SFTPProcessTransport(
            location: location,
            authentication: .key(identityFile: "/k"),
            dialer: HostDialer(host: location.host, resolvesIPv4: Self.bonjourOnly())
        )
        for arguments in [transport.batchArguments, transport.execArguments(command: "true")] {
            #expect(arguments.contains("dirnex-test@sftp.example.com"))
            #expect(!arguments.contains("AddressFamily=inet"))
        }
    }

    /// The identity half, and the reason the dial is not simply written into the location: the
    /// descriptor, the Keychain account and the saved record all key on the host the **user typed**,
    /// so a fallback must not move them. If it did, a saved server's password would be filed under a
    /// name nothing looks up and a restored tab would refuse to match its own endpoint.
    @Test("dialing a fallback host leaves the account's identity alone")
    func identityIsUnchangedByTheFallback() {
        let transport = FTPCurlTransport(
            location: Self.ftp,
            authentication: .password,
            dialer: HostDialer(host: Self.ftp.host, resolvesIPv4: Self.bonjourOnly())
        )
        #expect(transport.session.dial.host == "nas.local")
        #expect(transport.location.host == "nas")
        #expect(transport.location.descriptor == "ftp://dirnex-test@nas:21")
        #expect(transport.location.keychainAccount == "plain:dirnex-test@nas:21")
    }
}
