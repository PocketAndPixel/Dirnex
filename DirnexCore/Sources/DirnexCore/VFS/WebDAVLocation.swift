import Foundation

/// Where a `WebDAVBackend` connects: one account on one server, starting at one path — and no
/// secret.
///
/// The password never lives here, for the reason `FTPLocation` gives: the app resolves it from the
/// Keychain and hands it to `curl` through a `-K -` config file on **stdin**, never in `argv`
/// (NOTES.md ▸ curl). So a `WebDAVLocation` is safe to serialize into a tab, a saved server or a
/// `VFSBackendID`.
///
/// It needs one field the other remotes do not: ``rootPath``. A WebDAV account rarely starts at
/// the server's `/` — Nextcloud's is `/remote.php/dav/files/<user>/`, and a hosted service puts it
/// wherever it likes — so the pane's `/` is mapped onto that path, and every request is built by
/// prefixing it. It is part of the identity: two roots on one server are two places, with two
/// backend ids and two sets of restored tabs (PLAN.md §M32).
public struct WebDAVLocation: Sendable, Hashable, Codable {
    /// Host as the user typed it — a name, `nas`, or an address. What is *dialed* may differ
    /// (``HostNameFallback``); this is what keys the descriptor, the Keychain item and the saved
    /// record, so it never moves.
    public let host: String
    /// TCP port. 443 or 80 unless the user says otherwise; a Synology NAS uses 5006 and 5005.
    public let port: Int
    /// The account name. Empty means the server is reached without credentials at all, which a
    /// public share can be; nothing is filed in the Keychain for it.
    public let username: String
    /// HTTPS, or plain HTTP. Plain HTTP is a deliberate choice the connect sheet states, because
    /// Basic authentication sends the password with every request (PLAN.md §M32).
    public let usesTLS: Bool
    /// The server path the pane's `/` stands for, **decoded**, with a leading slash and no trailing
    /// one — or empty for the server's own root. Decoded because it is a path, not a URL: it is
    /// encoded with everything else when a request is built, so storing it encoded would encode
    /// it twice.
    public let rootPath: String

    public init(
        host: String,
        port: Int? = nil,
        username: String,
        usesTLS: Bool = true,
        rootPath: String = ""
    ) {
        self.host = host
        self.port = port ?? (usesTLS ? 443 : 80)
        self.username = username
        self.usesTLS = usesTLS
        self.rootPath = WebDAVLocation.normalizedRoot(rootPath)
    }

    /// `rootPath` in its one stored form: leading slash, no trailing slash, no empty segments, or
    /// empty for the server root. One form, so `/dav/`, `dav` and `/dav` cannot become three
    /// backend ids for one place.
    static func normalizedRoot(_ raw: String) -> String {
        let segments = raw.split(separator: "/", omittingEmptySubsequences: true)
        return segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
    }
}

public extension WebDAVLocation {
    /// The scheme a descriptor is spelled with: `davs://` for HTTPS and `dav://` for HTTP, the
    /// spelling GNOME and KDE use for the same thing. A scheme rather than a flag, as
    /// `FTPSecurity` argues: a saved server that lost it would come back as a different one.
    var scheme: String { usesTLS ? "davs://" : "dav://" }

    /// The stable, round-trippable descriptor stored inside a `VFSBackendID`:
    /// `<scheme><username>@<host>:<port><rootPath>`.
    ///
    /// The port is always present, and the root follows the authority directly, so it is
    /// recovered as everything from the first `/` on. The username is everything before the
    /// authority's **last** `@`, unlike `FTPLocation`'s first: hosted WebDAV services commonly
    /// log in with an e-mail address, and the root may hold one too
    /// (`/remote.php/dav/files/me@example.com`), which is why the authority is cut off first.
    var descriptor: String { "\(scheme)\(username)@\(host):\(port)\(rootPath)" }

    /// The backend id that addresses this account.
    var backendID: VFSBackendID { VFSBackendID(descriptor) }

    /// Parse a descriptor, or `nil` when it isn't a WebDAV one or is malformed.
    init?(descriptor: String) {
        // Longest scheme first, so `davs://` is never read as `dav://` with a stray `s`. Neither is a
        // prefix of the other here, but the rule is the house's and costs nothing (`FTPSecurity`).
        let schemes = [("davs://", true), ("dav://", false)]
        guard let (scheme, usesTLS) = schemes.first(where: { descriptor.hasPrefix($0.0) })
        else { return nil }
        let body = descriptor.dropFirst(scheme.count)

        let authorityEnd = body.firstIndex(of: "/") ?? body.endIndex
        let authority = body[..<authorityEnd]
        let rootPath = String(body[authorityEnd...])

        guard let atIndex = authority.lastIndex(of: "@") else { return nil }
        let username = String(authority[..<atIndex])
        let hostPort = authority[authority.index(after: atIndex)...]
        // The port follows the *last* colon, which is also what keeps a bracketed IPv6 literal
        // whole: `[::1]:8080`'s own colons all come before it.
        guard let colonIndex = hostPort.lastIndex(of: ":"),
              let port = Int(hostPort[hostPort.index(after: colonIndex)...]),
              (1...65535).contains(port)
        else { return nil }
        let host = String(hostPort[..<colonIndex])
        guard !host.isEmpty else { return nil }
        self.init(host: host, port: port, username: username, usesTLS: usesTLS, rootPath: rootPath)
    }

    /// Recover the account a backend id addresses, or `nil` when the id isn't a WebDAV id.
    init?(backendID: VFSBackendID) {
        self.init(descriptor: backendID.rawValue)
    }

    /// The origin every request is built on, the port spelled out only when it is not the scheme's
    /// default.
    ///
    /// `host` names what to *dial*, for the reason ``FTPLocation/url(forRemotePath:host:)`` gives:
    /// the location's host is its identity and must stay what the user typed, while the dialed
    /// name is what the resolver found (`nas` → `nas.local`).
    func origin(host dialHost: String? = nil) -> String {
        let scheme = usesTLS ? "https" : "http"
        let isDefaultPort = (usesTLS && port == 443) || (!usesTLS && port == 80)
        let authority = dialHost ?? host
        return isDefaultPort ? "\(scheme)://\(authority)" : "\(scheme)://\(authority):\(port)"
    }

    /// The account as a person writes it — the URL of its root, with the user name in front when
    /// there is one: `https://dirnex-test@nas:5006/`, `https://cloud.example.com/remote.php/dav/files/me`.
    ///
    /// For reading, not for dialing: the root is shown decoded, as it was typed, and an e-mail login
    /// keeps its own `@`. The descriptor stays the identity.
    var displayAddress: String {
        let scheme = usesTLS ? "https://" : "http://"
        let user = username.isEmpty ? "" : "\(username)@"
        let isDefaultPort = (usesTLS && port == 443) || (!usesTLS && port == 80)
        let authority = isDefaultPort ? host : "\(host):\(port)"
        return scheme + user + authority + (rootPath.isEmpty ? "/" : rootPath)
    }

    /// The server path a path inside the backend stands for — ``rootPath`` prefixed, decoded.
    func serverPath(forBackendPath backendPath: String) -> String {
        let path = VFSPath.normalize(backendPath)
        if rootPath.isEmpty { return path }
        return path == "/" ? rootPath : rootPath + path
    }

    /// The path inside the backend a server path stands for, or `nil` when it lies outside
    /// ``rootPath``.
    ///
    /// The prefix is compared as **bytes**. `String.hasPrefix` compares by canonical equivalence,
    /// so a root spelled with a precomposed é would claim a sibling folder spelled with a
    /// decomposed one — two different directories on the server.
    func backendPath(forServerPath serverPath: String) -> String? {
        let path = WebDAVHref.normalized(serverPath)
        if rootPath.isEmpty { return path }
        if WebDAVHref.samePath(path, rootPath) { return "/" }
        guard path.utf8.starts(with: (rootPath + "/").utf8) else { return nil }
        // The cut falls just before the `/` that ended the prefix, an ASCII byte, so the rest is
        // whole UTF-8.
        return String(path.utf8.dropFirst(rootPath.utf8.count))
    }

    /// The URL of one resource, the path percent-encoded to the strict rule in ``WebDAVHref``.
    ///
    /// A collection's URL carries a trailing slash. Apache answers a collection without one too
    /// (measured on the NAS, 2026-10-22), but RFC 4918 lets a server redirect it, and `curl -T`
    /// against a URL that *does* end in `/` appends the local file's name (NOTES.md ▸ curl for S3)
    /// — so the slash is a property of the request, decided here, rather than of the path.
    func url(forBackendPath backendPath: String, isCollection: Bool, host dialHost: String? = nil)
        -> String {
        let encoded = WebDAVHref.encodedPath(serverPath(forBackendPath: backendPath))
        let path = isCollection && !encoded.hasSuffix("/") ? encoded + "/" : encoded
        return origin(host: dialHost) + path
    }

    /// The Keychain service every WebDAV password is filed under.
    static var keychainService: String { "app.dirnex.webdav" }

    /// The Keychain account key for this account's password: `<scheme>:<user>@<host>:<port>`.
    ///
    /// The root is deliberately left out. Two roots on one server are two places reached with one
    /// account and one password, and keying on the root would ask for it again for each. The scheme
    /// stays in, as in ``FTPLocation/keychainAccount``: HTTP and HTTPS to one host are separate
    /// trust decisions.
    var keychainAccount: String {
        "\(usesTLS ? "https" : "http"):\(username)@\(host):\(port)"
    }

    /// Whether requests carry credentials at all.
    var hasCredentials: Bool { !username.isEmpty }
}

public extension VFSBackendID {
    /// The backend id addressing one WebDAV account.
    static func webDAV(_ location: WebDAVLocation) -> VFSBackendID { location.backendID }

    /// The WebDAV account this id addresses, or `nil` when it isn't a WebDAV id.
    var webDAVLocation: WebDAVLocation? { WebDAVLocation(backendID: self) }

    /// Whether this id addresses a WebDAV account, over HTTPS or HTTP.
    var isWebDAV: Bool { rawValue.hasPrefix("davs://") || rawValue.hasPrefix("dav://") }
}
