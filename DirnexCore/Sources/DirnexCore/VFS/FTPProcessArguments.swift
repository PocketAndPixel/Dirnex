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
    public let trust: FTPTrust
    public let tls: FTPTLSCompatibility
    /// Seconds allowed for the TCP/TLS connect.
    public let connectTimeout: Int
    /// Seconds allowed for the whole invocation. Generous for transfers, tight for metadata — an
    /// unbounded wait is what wedged the `sftp` transport before it bounded its own (docs/NOTES.md).
    public let maxTime: Int

    public init(
        location: FTPLocation,
        trust: FTPTrust = .systemDefault,
        tls: FTPTLSCompatibility = .negotiate,
        connectTimeout: Int = 15,
        maxTime: Int = 120
    ) {
        self.location = location
        self.trust = trust
        self.tls = tls
        self.connectTimeout = connectTimeout
        self.maxTime = maxTime
    }

    /// The same session with a different TLS policy — how the transport arms the 1.2 retry.
    public func with(tls: FTPTLSCompatibility) -> FTPSession {
        FTPSession(
            location: location,
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

    /// Flags every invocation carries: silence, fail-on-error, the security mode, the trust
    /// decision, the TLS policy and the time budget.
    public static func common(session: FTPSession) -> [String] {
        var arguments = [
            // `-sS`: no progress meter, but keep error text on stderr for classification.
            "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime)
        ]
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
        let path = remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
        return common(session: session) + configFromStandardInput + [url(session, path)]
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
        var arguments = common(session: session) + configFromStandardInput
        arguments += ["--upload-file", localPath, "--write-out", "%{size_upload}"]
        if resume { arguments += ["--continue-at", "-"] }
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
        if session.location.security == .explicit { arguments.append("--ssl-reqd") }
        if session.tls == .forceTLS12 { arguments += ["--tlsv1.2", "--tls-max", "1.2"] }
        return arguments + configFromStandardInput + [url(session, "/")]
    }

    /// The URL for a remote path, percent-encoded.
    static func url(_ session: FTPSession, _ remotePath: String) -> String {
        session.location.url(forRemotePath: percentEncoded(remotePath))
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

/// Builds the `curl` config file fed on **stdin** (`-K -`) — the one place a password appears, and
/// the reason it never appears in `argv` or on disk.
///
/// The escaping is not cosmetic. Probed 2026-07-25: a value containing an unescaped newline makes
/// `curl` read the remainder as further *config directives* and abort with
/// `'"' is unknown` — so an unescaped newline in a password is a config-injection surface, not a
/// formatting bug. `curl`'s config parser honours `\\`, `\"`, `\t`, `\r` and `\n` inside a
/// double-quoted value; all five are emitted.
public enum FTPConfigFile {
    /// The config text authenticating `location`, with `password` for a named account. Returns the
    /// anonymous form when the location is anonymous, in which case `password` is ignored — the
    /// conventional e-mail-shaped string is used and nothing is read from the Keychain.
    public static func credentials(for location: FTPLocation, password: String) -> String {
        let secret = location.isAnonymous ? anonymousPassword : password
        return "user = \(quote("\(location.username):\(secret)"))\n"
    }

    /// What the public login sends as its password. Any e-mail-shaped string is conventional; this
    /// one names the client without leaking anything about the user.
    public static let anonymousPassword = "dirnex@example.com"

    /// Quote a value for `curl`'s config parser, escaping every character that would otherwise end
    /// the value or start a new directive.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}

/// Builds the raw FTP commands sent with `curl -Q`. Pure and tested because this is the one place a
/// file name reaches the control connection **unquoted**.
///
/// FTP has no quoting: a command is a verb, a space, and the rest of the line as the argument, so a
/// name containing CR or LF would end the command and start another one the user never asked for —
/// `DELE a\r\nDELE important.txt` is two commands. There is nothing to escape it *with*, so such a
/// path is refused outright rather than sanitized. POSIX and Windows both forbid these characters
/// in names, so nothing legitimate is lost.
public enum FTPQuoteCommand {
    /// A path that cannot be expressed as an FTP command argument.
    public struct UnsafePath: Error, Equatable {
        public let path: String
    }

    public static func makeDirectory(_ remotePath: String) throws -> String {
        try command("MKD", remotePath)
    }

    public static func removeDirectory(_ remotePath: String) throws -> String {
        try command("RMD", remotePath)
    }

    public static func removeFile(_ remotePath: String) throws -> String {
        try command("DELE", remotePath)
    }

    /// The rename pair, in the order they must be sent: `RNFR` names the source, `RNTO` the
    /// destination, and the server keeps the pending rename between them — so they only work sent
    /// together on one connection.
    public static func rename(_ source: String, to destination: String) throws -> [String] {
        [try command("RNFR", source), try command("RNTO", destination)]
    }

    /// A verb and its raw path argument, rejecting anything that could inject a second command.
    static func command(_ verb: String, _ remotePath: String) throws -> String {
        guard isSafe(remotePath) else { throw UnsafePath(path: remotePath) }
        return "\(verb) \(remotePath)"
    }

    /// Whether a path can be sent as a command argument: no line breaks, and not empty. NUL is
    /// refused too — it cannot appear in a POSIX name and would truncate the C string.
    static func isSafe(_ remotePath: String) -> Bool {
        !remotePath.isEmpty && !remotePath.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
    }
}
