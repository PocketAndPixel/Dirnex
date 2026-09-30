import Foundation

/// How much the transport trusts the server's TLS certificate — the stored half of the FTPS trust
/// decision, and the type that makes the security invariant checkable.
///
/// **`--insecure` is only ever emitted alongside a pin.** That is the whole reason this is an enum
/// rather than a pair of optional flags: PLAN.md §M13 requires that trust be granted by fingerprint
/// and *never* by a blanket "don't verify", and with two independent booleans nothing would stop a
/// later edit from setting one without the other. Here the unpinned case cannot express it.
public enum FTPTrust: Sendable, Hashable {
    /// Verify against the system trust store, as `curl` does by default. A public FTPS host with a
    /// real certificate needs nothing else, and a failure here is what raises the trust prompt.
    case systemDefault
    /// The user has explicitly trusted a specific public key (`FTPCertificate.publicKeyPin`).
    /// Verification against the system store is suppressed — a self-signed certificate can never
    /// pass it, and its subject rarely even matches the address (measured) — and replaced by an
    /// exact key match, which `curl` enforces before any data moves.
    case pinned(publicKey: String)
}

/// Which TLS versions the transport lets `curl` negotiate.
public enum FTPTLSCompatibility: Sendable, Hashable {
    /// Let `curl` and the server agree — the default, and the only one that keeps TLS 1.3.
    case negotiate
    /// Pin the connection to TLS 1.2.
    ///
    /// **A workaround for a specific `curl`, not a property of FTPS.** Measured during M13 planning:
    /// on the system `curl` 8.7.1, an FTPS listing can come back with **zero bytes** and exit 18
    /// (`CURLE_PARTIAL_FILE`) when the data connection negotiates TLS 1.3, while `--tlsv1.2
    /// --tls-max 1.2` returns the correct listing. It reproduced on both of that `curl`'s TLS
    /// backends (SecureTransport, and LibreSSL via `CURL_SSL_BACKEND=openssl`), so it is not an
    /// Apple-API problem, and there is no newer `curl` on macOS to fall back to.
    ///
    /// It is **not** applied up front, deliberately. Forcing every server down to TLS 1.2 is a real
    /// downgrade for the ones that do 1.3 correctly, so the transport negotiates normally and
    /// retries with this only after seeing exit 18 — the exact, documented symptom. That keeps the
    /// stronger protocol wherever it works and confines the workaround to the servers that need it.
    /// Re-measure when the system `curl` next moves; the pin should eventually be deletable.
    case forceTLS12
}

/// Everything an invocation needs that isn't the operation itself — the account, the trust
/// decision, and the time budget. Bundled so each argument builder takes one parameter instead of
/// six, and so a new cross-cutting flag lands in one place.
public struct FTPSession: Sendable, Hashable {
    public let location: FTPLocation
    /// The name to dial and the address family to ask for — the account's own host unless a Bonjour
    /// fallback resolved where it did not (``HostNameFallback``). Every invocation carries it, which
    /// is why it lives here beside the trust decision rather than being threaded through each
    /// builder.
    public let dial: DialedHost
    public let trust: FTPTrust
    public let tls: FTPTLSCompatibility
    /// Seconds allowed for the TCP/TLS connect.
    public let connectTimeout: Int
    /// Seconds allowed for the whole invocation. Generous for transfers, tight for metadata — an
    /// unbounded wait is what wedged the `sftp` transport before it bounded its own (docs/NOTES.md).
    public let maxTime: Int

    /// `dial` defaults to the location's own host, which is exactly today's behaviour: a session
    /// nobody has resolved for dials what it was given and asks for no address family.
    public init(
        location: FTPLocation,
        dial: DialedHost? = nil,
        trust: FTPTrust = .systemDefault,
        tls: FTPTLSCompatibility = .negotiate,
        connectTimeout: Int = 15,
        maxTime: Int = 120
    ) {
        self.location = location
        self.dial = dial ?? .asTyped(location.host)
        self.trust = trust
        self.tls = tls
        self.connectTimeout = connectTimeout
        self.maxTime = maxTime
    }

    /// The same session with a different time budget — how a caller arms a long transfer without
    /// loosening the metadata calls that share the connection settings. `S3Session` has the same
    /// pair, and for the same reason.
    public func with(maxTime: Int) -> FTPSession {
        FTPSession(
            location: location,
            dial: dial,
            trust: trust,
            tls: tls,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        )
    }

    /// The same session with a different TLS policy — how the transport arms the 1.2 retry.
    public func with(tls: FTPTLSCompatibility) -> FTPSession {
        FTPSession(
            location: location,
            dial: dial,
            trust: trust,
            tls: tls,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        )
    }
}

/// Builds the `curl` process arguments for each FTP operation. Pure and tested so the
/// security-sensitive assembly — which TLS flags are offered, whether verification is suppressed,
/// and crucially that **no credential is ever placed in `argv`** — is verified without spawning
/// anything, the same reason `SFTPProcessArguments` is pure.
///
/// The credential travels separately, through ``FTPConfigFile`` on **stdin** (`-K -`). Probed:
/// `-u user:pass` is visible to any `ps` on the machine, and a config *file* would be readable on
/// disk; stdin is neither. This is the same principle `SFTPAskpassHelper` already follows.
public enum FTPProcessArguments {
    /// Read the credential (and the URL-independent auth settings) from stdin.
    static let configFromStandardInput = ["-K", "-"]

    /// Ask the server to speak **UTF-8** for file names, allowed to fail (RFC 2640).
    ///
    /// Without it a server is free to use whatever code page it defaults to, and a Synology NAS
    /// defaults to CP1252 — which corrupts names in *both* directions, measured 2026-09-09 against
    /// a real DSM server holding `DSC_0697-Панорама.jpg`:
    ///
    /// - **Reading**, the server converts the on-disk UTF-8 name into its code page for `LIST` and
    ///   writes one **`0x7F` (DEL)** per character it cannot map — the row arrived as
    ///   `DSC_0697-\u{7F}…\u{7F}.jpg`. That is *valid UTF-8*, so nothing fails to decode and
    ///   ``FTPListingParser`` is handed a name it parses perfectly; the DELs simply do not draw, so
    ///   the pane showed `DSC_0697-.jpg` and every verb built from that name addressed a file that
    ///   is not there.
    /// - **Writing**, the server reads our UTF-8 bytes *as* CP1252 and stores the result: an upload
    ///   named `Панорама` landed on the server as `ÐŸÐ°Ð½Ð¾Ñ€Ð°Ð¼Ð°` (`d0`→`Ð`, `9f`→`Ÿ`), which is
    ///   permanent corruption of somebody's file name rather than a display problem. The same
    ///   reasoning covers every **path** we send, since a URL carries percent-encoded UTF-8.
    ///
    /// `curl` offers no option for this and never negotiates it itself — probed, it does not even
    /// send `FEAT` — so a quote command is the only route. After it the same server answers
    /// `200 OK, UTF-8 enabled` and lists `d0 9f d0 b0 …` verbatim.
    ///
    /// **The `*` is load-bearing**, not defensive tidiness: it marks the command allowed-to-fail, and
    /// a server that refuses `OPTS` otherwise fails the *whole invocation*. Measured against a
    /// server that refuses it — unprefixed, `curl` exits **21** printing
    /// `QUOT command failed with 501`, and that `501` is exactly what
    /// ``FTPTransportError/classify(exitCode:stderr:)`` scans stderr for, so an unsupported server
    /// would have every operation fail *and* be misdiagnosed by the server's own reply code.
    /// Prefixed, the same run exits **0** with stderr **empty**, so a server that cannot do this is
    /// left exactly as it was.
    ///
    /// It is sent **pre-transfer** and therefore first, which is what the ordering needs: `RNFR`/
    /// `RNTO`, `MKD` and `DELE` all carry names of their own and must be spoken after the encoding
    /// is settled, not before.
    static let utf8Negotiation = "*OPTS UTF8 ON"

    /// Flags every invocation carries: silence, fail-on-error, the security mode, the trust
    /// decision, the TLS policy and the time budget.
    ///
    /// `showingProgress` is the one an **upload** has to turn on, and only an upload. `-s` suppresses
    /// the progress meter, which for a `--upload-file` is the only observable there is: nothing
    /// local changes as the bytes go out, so with the meter silenced the transfer reports once, when
    /// it is over — measured 2026-08-16 against a throttled local server as 8 seconds of silence for
    /// 8 MB, the same shape a user reported on S3 at 29 MB and 99 seconds. `-S` alone keeps the
    /// error text `-sS` was chosen for while letting the meter through.
    ///
    /// A **download** deliberately keeps `-sS`: its destination is a local file that grows, so the
    /// transport reports exact bytes by watching it, where the meter could only offer a rounded
    /// percentage.
    public static func common(session: FTPSession, showingProgress: Bool = false) -> [String] {
        var arguments = [
            // `-sS`: no progress meter, but keep error text on stderr for classification. `-S` alone
            // is the same minus the silencing, for the one verb that needs the meter to report at
            // all.
            showingProgress ? "-S" : "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime)
        ]
        // Only ever set once an IPv4 address has been observed for the dialed name, so this
        // withholds a query whose answer is already known rather than a route that might work. On
        // an mDNS name that is five seconds *per invocation*, and every FTP verb is a fresh `curl`.
        if session.dial.restrictsToIPv4 { arguments.append("-4") }
        // Every invocation, because every one of them either reads a name or sends one — see
        // `utf8Negotiation` for what a server does with the bytes otherwise.
        arguments += ["--quote", utf8Negotiation]
        arguments += securityArguments(session: session)
        return arguments
    }

    /// The TLS half of the common flags — split out because it is the part worth reading alone.
    private static func securityArguments(session: FTPSession) -> [String] {
        var arguments: [String] = []
        // Explicit FTPS is `ftp://` plus a *required* upgrade. `--ssl-reqd` rather than `--ssl`:
        // the latter silently continues in cleartext when the server declines, which would hand a
        // password to a downgrade. Implicit FTPS needs no flag — its `ftps://` URL is the signal.
        if session.location.security == .explicit {
            arguments.append("--ssl-reqd")
        }
        guard session.location.security.usesTLS else { return arguments }

        switch session.trust {
        case .systemDefault:
            break
        case let .pinned(publicKey):
            // The invariant: these two always travel together. See `FTPTrust`.
            arguments += ["--insecure", "--pinnedpubkey", "sha256//\(publicKey)"]
        }
        if session.tls == .forceTLS12 {
            arguments += ["--tlsv1.2", "--tls-max", "1.2"]
        }
        return arguments
    }

    /// List a remote directory. The trailing slash is what makes `curl` send `LIST` rather than
    /// fetch a file of that name, so it is appended here rather than left to callers.
    public static func list(session: FTPSession, remotePath: String) -> [String] {
        common(session: session) + configFromStandardInput + [listingURL(session, remotePath)]
    }

    /// The URL that makes `curl` send `LIST` for `remotePath` — the trailing slash and the
    /// percent-encoding in one place, since the batched listing needs exactly the same rule and two
    /// spellings of it would be one spelling away from fetching a *file* of that name instead.
    static func listingURL(_ session: FTPSession, _ remotePath: String) -> String {
        url(session, remotePath.hasSuffix("/") ? remotePath : remotePath + "/")
    }

    /// Download a remote file to `localPath`, optionally resuming from what is already there.
    /// `-w '%{size_download}'` is what makes the transferred delta readable without arithmetic.
    public static func download(
        session: FTPSession,
        remotePath: String,
        localPath: String,
        resume: Bool
    ) -> [String] {
        var arguments = common(session: session) + configFromStandardInput
        arguments += ["--output", localPath, "--write-out", "%{size_download}"]
        if resume { arguments += ["--continue-at", "-"] }
        return arguments + [url(session, remotePath)]
    }

    /// Upload a local file to a remote path. `--continue-at -` on an upload makes `curl` ask the
    /// server for the current remote size and send only the remainder — verified live, byte-exact.
    public static func upload(
        session: FTPSession,
        localPath: String,
        remotePath: String,
        resume: Bool
    ) -> [String] {
        var arguments = common(session: session, showingProgress: true) + configFromStandardInput
        arguments += ["--upload-file", localPath, "--write-out", "%{size_upload}"]
        if resume { arguments += ["--continue-at", "-"] }
        return arguments + [url(session, remotePath)]
    }

    /// Upload `localPath` — expected to be an **empty** file — to create `remotePath`, the ⇧F4
    /// "Edit File…" route (PLAN.md §M11).
    ///
    /// `append` picks the FTP verb, and the choice is the whole reason this is not
    /// ``upload(session:localPath:remotePath:resume:)`` with a flag. Measured 2026-08-23 against a
    /// real server, with `-v` read for the verb actually sent:
    ///
    /// - **`--append` sends `APPE`**, which creates the file when it is absent and — appending zero
    ///   bytes — leaves an existing one **byte-for-byte untouched**. That is as close to
    ///   create-if-absent as FTP gets, and it is what makes losing the race against
    ///   ``RemoteTransportBackend/createFile(at:)``'s `stat` harmless rather than destructive.
    /// - **Plain `--upload-file` sends `STOR`**, which truncates. It is nonetheless the fallback,
    ///   because `APPE` is not universally offered: a server that grants `STOR` and refuses `APPE`
    ///   answers **exit 25 / 550**, so an `APPE`-only create would simply fail there.
    ///
    /// Two flags this deliberately does *not* borrow from `upload`. No `-w '%{size_upload}'`: the
    /// answer is always 0 and the caller has nothing to reconcile. And **no `showingProgress`** —
    /// `-S` exists so a long transfer's meter can be read, and letting a meter onto stderr for an
    /// empty file would only put a three-digit speed column in front of the classifier that reads
    /// FTP reply codes out of that same stream (docs/NOTES.md ▸ curl).
    ///
    /// The URL must not end in `/`, which is why `remotePath` is passed through untouched where
    /// ``list(session:remotePath:)`` appends one: `curl -T` against a trailing slash appends the
    /// *local* file's basename, so the create would land under the temporary file's name instead of
    /// the user's (measured over FTP, and the same trap S3's own upload URL carries).
    public static func createFile(
        session: FTPSession,
        localPath: String,
        remotePath: String,
        append: Bool
    ) -> [String] {
        var arguments = common(session: session) + configFromStandardInput
        if append { arguments.append("--append") }
        arguments += ["--upload-file", localPath]
        return arguments + [url(session, remotePath)]
    }

    /// Ask for one file's metadata only (`SIZE` + `MDTM`, surfaced as `Content-Length` and
    /// `Last-Modified`). The one path that yields an **exact, zone-anchored** mtime — a `LIST`
    /// stamp has neither year nor zone — so it is worth a round trip for a single item and never
    /// for a listing.
    public static func head(session: FTPSession, remotePath: String) -> [String] {
        common(session: session) + configFromStandardInput + ["--head", url(session, remotePath)]
    }

    /// Send raw FTP commands and no data transfer. Each command is a `-Q` argument; they are sent
    /// in order on one connection, which is what makes `RNFR`/`RNTO` expressible at all.
    public static func quote(
        session: FTPSession,
        commands: [String],
        atPath remotePath: String = "/"
    ) -> [String] {
        var arguments = common(session: session) + configFromStandardInput
        for command in commands {
            arguments += ["--quote", command]
        }
        // The commands do the work; the URL only says where to connect and must not transfer.
        arguments += ["--output", "/dev/null"]
        return arguments + [url(session, remotePath.hasSuffix("/") ? remotePath : remotePath + "/")]
    }

    /// Fetch the server's certificate *without* trusting it, so the app can show the user what it
    /// is being asked to accept. This is the one invocation that passes `--insecure` without a pin,
    /// and it is safe precisely because it transfers nothing: it connects, prints the certificate,
    /// and discards the body.
    public static func certificateProbe(session: FTPSession) -> [String] {
        var arguments = [
            "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime),
            "--insecure",
            "--write-out", "%{certs}",
            "--output", "/dev/null"
        ]
        // This one assembles its own flags rather than going through `common`, so the address
        // family has to be repeated here — it is a real connection to the dialed host like any
        // other, and it is the *first* one a trust prompt makes.
        if session.dial.restrictsToIPv4 { arguments.append("-4") }
        if session.location.security == .explicit { arguments.append("--ssl-reqd") }
        if session.tls == .forceTLS12 { arguments += ["--tlsv1.2", "--tls-max", "1.2"] }
        return arguments + configFromStandardInput + [url(session, "/")]
    }

    /// The URL for a remote path, percent-encoded.
    static func url(_ session: FTPSession, _ remotePath: String) -> String {
        session.location.url(forRemotePath: percentEncoded(remotePath), host: session.dial.host)
    }

    /// Percent-encode a remote path for a `curl` URL, keeping only unreserved characters and the
    /// path separator literal.
    ///
    /// Deliberately stricter than `CharacterSet.urlPathAllowed`, which permits the sub-delimiters:
    /// a `;` in a name would otherwise be read as FTP's `;type=a` URL suffix and a `#` as a
    /// fragment, so a legal file name could change which file is fetched. Encoding everything
    /// outside `A-Za-z0-9-._~/` makes that class impossible without needing to enumerate it.
    static func percentEncoded(_ remotePath: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return remotePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? remotePath
    }
}
