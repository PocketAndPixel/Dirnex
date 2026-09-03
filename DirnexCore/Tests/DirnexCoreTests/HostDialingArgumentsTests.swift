import Testing
@testable import DirnexCore

/// What a resolved dial does to the two transports' arguments: which host is contacted, and the
/// address-family flag that keeps an mDNS name from costing five seconds on every invocation.
///
/// Each claim is paired with its narrowness control — an ordinary dotted host must come out
/// **byte-identical** to what it produces today — because the failure this feature could introduce
/// is not "the fallback did not happen" but "every server in the world is now dialed differently".
@Suite("Dialed host in transport arguments")
struct HostDialingArgumentsTests {
    private static let ftp = FTPLocation(
        host: "nas", port: 21, username: "dirnex-test", security: .plain
    )
    private static let sftp = SFTPLocation(host: "nas", port: 22, username: "dirnex-test")
    private static let resolved = DialedHost(host: "nas.local", restrictsToIPv4: true)

    // MARK: - curl

    @Test("a resolved dial puts the fallback host in the URL and asks curl for IPv4")
    func ftpUsesDialedHost() {
        let session = FTPSession(location: Self.ftp, dial: Self.resolved)
        let arguments = FTPProcessArguments.list(session: session, remotePath: "/pub")
        #expect(arguments.contains("-4"))
        #expect(arguments.contains("ftp://nas.local:21/pub/"))
        #expect(!arguments.contains("ftp://nas:21/pub/"))
    }

    /// The control. A session nobody resolved for — every dotted host and every IP literal — must
    /// produce exactly what it produces today, flag included.
    @Test("an unresolved session is unchanged: the typed host, and no address-family flag")
    func ftpWithoutDialIsUnchanged() {
        let session = FTPSession(location: Self.ftp)
        let arguments = FTPProcessArguments.list(session: session, remotePath: "/pub")
        #expect(!arguments.contains("-4"))
        #expect(arguments.contains("ftp://nas:21/pub/"))
    }

    /// The certificate probe assembles its own flags instead of going through `common`, so it is the
    /// one builder that can silently miss this — and it is the *first* connection a trust prompt
    /// makes, so missing it would put a five-second stall in front of the dialog.
    @Test("the certificate probe carries the address family too")
    func certificateProbeCarriesAddressFamily() {
        let secure = FTPLocation(
            host: "nas", port: 21, username: "dirnex-test", security: .explicit
        )
        let resolved = FTPProcessArguments.certificateProbe(
            session: FTPSession(location: secure, dial: Self.resolved)
        )
        #expect(resolved.contains("-4"))
        #expect(!FTPProcessArguments.certificateProbe(
            session: FTPSession(location: secure)
        ).contains("-4"))
    }

    /// `curl` reads one option set per transfer, so a batched or segmented run has to repeat the
    /// flag per **section**. In `argv` it would be relying on an option leaking across a `next`
    /// boundary — which is the same reason the TLS options are already per section.
    @Test("a batched listing repeats the address family in every section")
    func batchedListingCarriesAddressFamily() {
        let requests = [
            FTPListingRequest(remotePath: "/a", outputPath: "/tmp/a"),
            FTPListingRequest(remotePath: "/b", outputPath: "/tmp/b")
        ]
        let invocation = FTPProcessArguments.listDirectories(
            session: FTPSession(location: Self.ftp, dial: Self.resolved),
            requests: requests,
            credentials: "user = \"x:y\"\n"
        )
        let sections = invocation.configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        for section in sections {
            #expect(section.contains("ipv4\n"))
            #expect(section.contains("nas.local"))
        }
    }

    @Test("an unresolved batched listing carries no address family in any section")
    func batchedListingControl() {
        let invocation = FTPProcessArguments.listDirectories(
            session: FTPSession(location: Self.ftp),
            requests: [FTPListingRequest(remotePath: "/a", outputPath: "/tmp/a")],
            credentials: "user = \"x:y\"\n"
        )
        #expect(!invocation.configuration.contains("ipv4"))
    }

    // MARK: - ssh

    @Test("a resolved dial is the ssh target, and the address family is asked for")
    func sftpUsesDialedHost() {
        let arguments = SFTPProcessArguments.batch(
            location: Self.sftp,
            dial: Self.resolved,
            authentication: .key(identityFile: "/k"),
            connectTimeout: 15
        )
        #expect(arguments.contains("dirnex-test@nas.local"))
        #expect(!arguments.contains("dirnex-test@nas"))
        #expect(arguments.contains("AddressFamily=inet"))
    }

    @Test("an unresolved sftp batch is unchanged: the typed target, no address family")
    func sftpWithoutDialIsUnchanged() {
        let arguments = SFTPProcessArguments.batch(
            location: Self.sftp,
            dial: .asTyped(Self.sftp.host),
            authentication: .key(identityFile: "/k"),
            connectTimeout: 15
        )
        #expect(arguments.contains("dirnex-test@nas"))
        #expect(!arguments.contains("AddressFamily=inet"))
    }

    /// The exec channel must contact the same host as the browsing one, or the search shortcut
    /// would reach a different machine than the pane it is searching.
    @Test("the exec channel dials exactly what the batch channel dials")
    func execMatchesBatch() {
        for authentication in [SFTPAuthentication.key(identityFile: "/k"), .password] {
            let batch = SFTPProcessArguments.batch(
                location: Self.sftp,
                dial: Self.resolved,
                authentication: authentication,
                connectTimeout: 15
            )
            let exec = SFTPProcessArguments.exec(
                location: Self.sftp,
                dial: Self.resolved,
                authentication: authentication,
                connectTimeout: 15,
                command: "true"
            )
            #expect(batch.contains("dirnex-test@nas.local"))
            #expect(exec.contains("dirnex-test@nas.local"))
            #expect(batch.contains("AddressFamily=inet"))
            #expect(exec.contains("AddressFamily=inet"))
        }
    }

    /// The password path assembles its own option list ahead of the shared one, which is exactly
    /// where a flag added to `common` can be missed.
    @Test("password auth carries the address family as well as key auth")
    func passwordAuthCarriesAddressFamily() {
        let arguments = SFTPProcessArguments.batch(
            location: Self.sftp,
            dial: Self.resolved,
            authentication: .password,
            connectTimeout: 15
        )
        #expect(arguments.contains("AddressFamily=inet"))
        #expect(arguments.contains("dirnex-test@nas.local"))
    }
}
