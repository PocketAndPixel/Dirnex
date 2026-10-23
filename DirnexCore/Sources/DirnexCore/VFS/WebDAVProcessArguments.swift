import Foundation

/// How a WebDAV connection proves who it is. Read once from the server's challenge by
/// ``WebDAVConnectProbe`` and kept for the connection, rather than left to `curl --anyauth`, which
/// pays a 401 round trip on every request to rediscover the same answer (PLAN.md §M32).
public enum WebDAVAuthScheme: String, Sendable, Hashable, Codable, CaseIterable {
    /// RFC 7617. Sent **preemptively**, so a request costs one round trip.
    case basic
    /// RFC 7616. Never preemptive: every `curl` is a new process with no nonce, so each invocation
    /// is a 401 and then the real request — measured against macOS's Apache 2026-10-23, two
    /// requests in its log for every one asked for. What it buys is a password that never crosses
    /// the wire, which matters only over plain HTTP.
    case digest
}

/// Everything a WebDAV invocation needs that isn't the operation itself — the account, the dialed
/// host, the trust decision, the scheme and the time budget. Bundled for the reason `FTPSession`
/// is: each argument builder takes one parameter, and a cross-cutting flag lands in one place.
public struct WebDAVSession: Sendable, Hashable {
    public let location: WebDAVLocation
    /// What to dial and whether to hold the lookup to IPv4 (``HostNameFallback``). An mDNS name
    /// without `-4` costs five seconds a request, and every WebDAV verb is a fresh `curl`.
    public let dial: DialedHost
    /// The certificate decision, shared with FTPS on purpose: the NAS presents the same
    /// self-signed certificate on its WebDAV port as on its FTPS one, with an identical key pin
    /// (PLAN.md §M32), so the trust sheet and the pin carry over unchanged.
    public let trust: FTPTrust
    /// The scheme credentials go out with, or `nil` for none at all — a public share, or the
    /// probe's first request, which asks the server what it wants before sending anything.
    public let authentication: WebDAVAuthScheme?
    /// Seconds allowed for the TCP/TLS connect.
    public let connectTimeout: Int
    /// Seconds allowed for the whole invocation. Generous for transfers, tight for metadata.
    public let maxTime: Int

    public init(
        location: WebDAVLocation,
        dial: DialedHost? = nil,
        trust: FTPTrust = .systemDefault,
        authentication: WebDAVAuthScheme? = .basic,
        connectTimeout: Int = 15,
        maxTime: Int = 120
    ) {
        self.location = location
        self.dial = dial ?? .asTyped(location.host)
        self.trust = trust
        self.authentication = authentication
        self.connectTimeout = connectTimeout
        self.maxTime = maxTime
    }

    /// Whether this session's requests carry the account's credentials: a scheme to send them
    /// with, and an account to send. The transport reads the same answer to decide whether to
    /// write the password to `curl`'s stdin, so the two cannot disagree.
    public var sendsCredentials: Bool { authentication != nil && location.hasCredentials }

    /// The same session with a different time budget — how a transfer is armed without loosening
    /// the metadata calls.
    public func with(maxTime: Int) -> WebDAVSession {
        WebDAVSession(
            location: location,
            dial: dial,
            trust: trust,
            authentication: authentication,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        )
    }

    /// The same session authenticating differently — how the probe asks first with nothing and
    /// then with the scheme the server named.
    public func with(authentication: WebDAVAuthScheme?) -> WebDAVSession {
        WebDAVSession(
            location: location,
            dial: dial,
            trust: trust,
            authentication: authentication,
            connectTimeout: connectTimeout,
            maxTime: maxTime
        )
    }
}

/// How deep a PROPFIND reaches. There is no `infinity` case, and that is the decision rather than a
/// gap: the NAS refuses it (403), and on a server that allows it the answer is one unbounded
/// document parsed whole. A PROPFIND with **no** `Depth` header is infinity by RFC 4918, so the
/// header is never left off either (PLAN.md §M32).
public enum WebDAVDepth: String, Sendable, Hashable {
    /// The resource alone — a stat.
    case zero = "0"
    /// The resource and its children — a listing.
    case one = "1"
}

/// Builds the `curl` arguments for each WebDAV request. Pure and tested for the reason
/// `FTPProcessArguments` is: what is security-sensitive about the assembly — that **no secret ever
/// reaches `argv`**, that `--insecure` never travels without a pin, that a scheme is never guessed
/// — is checked without spawning anything.
public enum WebDAVProcessArguments {
    /// Read the credential from stdin, as FTP and S3 do (NOTES.md ▸ curl).
    static let configFromStandardInput = ["-K", "-"]

    /// The named properties every PROPFIND asks for: what a row needs and nothing else. Named
    /// rather than `<allprop/>` because allprop also returns every dead property a client ever
    /// stored on the file — the NAS keeps Windows' `Win32LastModifiedTime` that way — and a lock
    /// discovery per row, none of which a listing reads.
    static let propfindBody = [
        #"<?xml version="1.0" encoding="utf-8"?>"#,
        #"<D:propfind xmlns:D="DAV:"><D:prop>"#,
        "<D:resourcetype/><D:getcontentlength/><D:getlastmodified/>",
        "<D:creationdate/><D:getetag/><D:getcontenttype/>",
        "</D:prop></D:propfind>"
    ].joined()

    /// Flags every invocation carries.
    ///
    /// - **`-q` comes first**, because `curl` otherwise reads `~/.curlrc` before anything here.
    ///   Measured 2026-10-23: a `.curlrc` holding `--head` turned a GET into a HEAD that downloaded
    ///   nothing and still exited 0, and `-q` as the first argument stopped it. It has to be first;
    ///   anywhere else `curl` has already read the file.
    /// - **No `--location`.** A redirect is an answer worth reading — the probe reports where the
    ///   server points, typically `http` to `https` — and following one would re-send the request,
    ///   credentials included, to a place nobody chose.
    /// - **No `--fail`** except on a download, for S3's reason: a refusal's body is part of the
    ///   classification (a 207 or 424 names its members), and only a byte copy is better off with
    ///   nothing written (``download(session:backendPath:localPath:resume:)``).
    /// - **The scheme is spelled out** — `--basic` or `--digest` — rather than left to `curl`'s
    ///   default, so a scheme the probe chose is the scheme that is sent.
    public static func common(session: WebDAVSession, showingProgress: Bool = false) -> [String] {
        var arguments = [
            "-q",
            showingProgress ? "-S" : "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime)
        ]
        if session.dial.restrictsToIPv4 { arguments.append("-4") }
        if session.sendsCredentials, let scheme = session.authentication {
            arguments.append(scheme == .digest ? "--digest" : "--basic")
            arguments += configFromStandardInput
        }
        arguments += trustArguments(session: session)
        return arguments + ["--write-out", WebDAVWriteOut.format]
    }

    /// `--insecure` and the pin, always together (``FTPTrust``), and only over HTTPS — over plain
    /// HTTP there is no certificate for either to be about.
    private static func trustArguments(session: WebDAVSession) -> [String] {
        guard session.location.usesTLS, case let .pinned(publicKey) = session.trust else { return [] }
        return ["--insecure", "--pinnedpubkey", "sha256//\(publicKey)"]
    }

    /// One PROPFIND for the named properties, at `depth`.
    ///
    /// `isCollection` decides the trailing slash (``WebDAVLocation/url(forBackendPath:isCollection:host:)``):
    /// a listing names a folder and says so; a stat does not know what it is asking about and says
    /// nothing. The body is inline: it is two hundred bytes with no secret in it, and stdin is the
    /// credential's.
    public static func propfind(
        session: WebDAVSession,
        backendPath: String,
        depth: WebDAVDepth,
        isCollection: Bool
    ) -> [String] {
        common(session: session)
            + ["-X", "PROPFIND", "-H", "Depth: \(depth.rawValue)"]
            + ["-H", #"Content-Type: application/xml; charset="utf-8""#]
            + ["--data-binary", propfindBody]
            + [url(session, backendPath, isCollection: isCollection)]
    }

    /// Download one file to `localPath`, resuming from what is already there when `resume`.
    ///
    /// `--fail` is here for the reason S3's download carries it, and it was measured again on the
    /// NAS 2026-10-23: a GET of a missing file with it exits 22, the write-out still says 404, and
    /// **no file is created**. Without it the 404 page would be saved under the file's own name.
    /// `--remove-on-error` stays out, since it would delete the partial `--continue-at` resumes
    /// from.
    ///
    /// Resume is `-C -`. Measured on the NAS: a 3 129 010-byte file resumed from 100 000 bytes
    /// answered 206 with `size_download` 3 029 010 and compared identical, and resuming onto the
    /// complete file answered 416 and exited 0 with the file untouched — so the backend checks the
    /// remote size before asking (``WebDAVBackend``).
    public static func download(
        session: WebDAVSession,
        backendPath: String,
        localPath: String,
        resume: Bool
    ) -> [String] {
        var arguments = common(session: session) + ["--fail", "--output", localPath]
        if resume { arguments += ["--continue-at", "-"] }
        return arguments + [url(session, backendPath, isCollection: false)]
    }

    /// Fetch the server's certificate without trusting it, so the trust sheet can show what it is
    /// being asked to accept — FTPS's probe, and safe for the same reason: it sends no credential
    /// and keeps no body. The one invocation that passes `--insecure` without a pin.
    public static func certificateProbe(session: WebDAVSession) -> [String] {
        var arguments = [
            "-q", "-sS",
            "--connect-timeout", String(session.connectTimeout),
            "--max-time", String(session.maxTime),
            "--insecure",
            "--write-out", "%{certs}",
            "--output", "/dev/null",
            "-X", "OPTIONS"
        ]
        if session.dial.restrictsToIPv4 { arguments.append("-4") }
        return arguments + [url(session, "/", isCollection: true)]
    }

    /// The request URL for a path inside the backend, built on the dialed host.
    static func url(_ session: WebDAVSession, _ backendPath: String, isCollection: Bool) -> String {
        session.location.url(
            forBackendPath: backendPath,
            isCollection: isCollection,
            host: session.dial.host
        )
    }
}

/// The `curl` config fed on stdin (`-K -`) — the one place a WebDAV password appears.
///
/// `curl` splits `user` at its first `:`, so a password may contain one and a user name may not,
/// which is also RFC 7617's rule for Basic. The escaping is `FTPConfigFile`'s, and an injection
/// guard rather than formatting: an unescaped newline makes `curl` read the rest as directives.
public enum WebDAVConfigFile {
    public static func credentials(username: String, password: String) -> String {
        "user = \(FTPConfigFile.quote("\(username):\(password)"))\n"
    }
}
