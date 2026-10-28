import Foundation

/// What a person types or pastes into the connect sheet's Host field, split into the fields a
/// ``WebDAVLocation`` is built from (PLAN.md §M32 Slice 3).
///
/// A WebDAV account is usually handed over as a URL — Nextcloud shows
/// `https://cloud.example.com/remote.php/dav/files/me/` under Settings ▸ WebDAV, a NAS's manual
/// gives `https://nas:5006` — so the Host field takes one whole and the sheet spreads it over the
/// security, port, path and user fields. A bare host and `host:port` work too, which is what every
/// other protocol's Host field takes.
///
/// Only what was written is reported. A field the text did not mention is `nil`, so the sheet
/// leaves that field as the user set it: `nas:5006` changes the port and keeps the chosen scheme.
public struct WebDAVAddress: Sendable, Equatable {
    /// The host as typed — a name, an address, or a bracketed IPv6 literal.
    public let host: String
    /// The port, when the text named one.
    public let port: Int?
    /// HTTPS or HTTP, when the text carried a scheme.
    public let usesTLS: Bool?
    /// The root path, decoded and normalized (``WebDAVLocation/normalizedRoot(_:)``), when the text
    /// carried a path. Empty for an explicit `/`.
    public let rootPath: String?
    /// The user name from a URL's user info, when it carried one. A password there is ignored: it
    /// would land in a text field anyone looking at the screen can read.
    public let username: String?

    public init(
        host: String,
        port: Int? = nil,
        usesTLS: Bool? = nil,
        rootPath: String? = nil,
        username: String? = nil
    ) {
        self.host = host
        self.port = port
        self.usesTLS = usesTLS
        self.rootPath = rootPath
        self.username = username
    }

    /// Whether the text said anything beyond a host name — the sheet's cue to rewrite the field.
    public var carriesMoreThanHost: Bool {
        port != nil || usesTLS != nil || rootPath != nil || username != nil
    }

    /// The schemes accepted, and whether each is HTTPS. `dav`/`davs` are GNOME's and KDE's
    /// spellings and the descriptor's own, `webdav`/`webdavs` are what some NAS manuals print.
    private static let schemes: [String: Bool] = [
        "https": true, "davs": true, "webdavs": true,
        "http": false, "dav": false, "webdav": false
    ]

    /// Split `text`, or `nil` when it is empty or cannot be a WebDAV address: an unknown scheme,
    /// a port out of range, no host, or a URL path that does not decode to a server path.
    ///
    /// A **URL** (one with a scheme) is read as a URL: a `?` or `#` ends the path, the path is
    /// percent-decoded segment by segment with ``WebDAVHref/serverPath(fromHref:)``'s refusals, and
    /// the user name is decoded too. **Without** a scheme the text is what a Host field holds, and a
    /// path after the first `/` is taken literally, as the Path field takes it — `%` is then a
    /// character, which is what it is in a folder name.
    public static func parse(_ text: String) -> WebDAVAddress? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var usesTLS: Bool?
        if let separator = rest.range(of: "://") {
            guard let isTLS = schemes[rest[..<separator.lowerBound].lowercased()] else { return nil }
            usesTLS = isTLS
            rest = rest[separator.upperBound...]
        }
        let isURL = usesTLS != nil
        let authorityEnd = rest.firstIndex {
            $0 == "/" || (isURL && ($0 == "?" || $0 == "#"))
        } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        let pathPart = rest[authorityEnd...]

        var username: String?
        if let at = authority.lastIndex(of: "@") {
            let name = authority[..<at].split(
                separator: ":",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            .first.map(String.init) ?? ""
            username = isURL ? (name.removingPercentEncoding ?? name) : name
            authority = authority[authority.index(after: at)...]
        }

        guard let (host, port) = hostAndPort(authority), !host.isEmpty else { return nil }

        var rootPath: String?
        if !pathPart.isEmpty {
            if isURL {
                // A query or fragment straight after the authority is a URL of the server's root.
                let href = pathPart.hasPrefix("/") ? String(pathPart) : "/"
                guard let decoded = WebDAVHref.serverPath(fromHref: href) else { return nil }
                rootPath = WebDAVLocation.normalizedRoot(decoded)
            } else {
                rootPath = WebDAVLocation.normalizedRoot(String(pathPart))
            }
        }
        return WebDAVAddress(
            host: String(host),
            port: port,
            usesTLS: usesTLS,
            rootPath: rootPath,
            username: username.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The host and the port of an authority, or `nil` when a port is there and is not one.
    ///
    /// A bracketed IPv6 literal keeps its brackets, since the location dials its host verbatim
    /// inside a URL. An unbracketed one has colons a port cannot be told from, so a host with more
    /// than one colon is taken whole, with no port.
    private static func hostAndPort(_ authority: Substring) -> (Substring, Int?)? {
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let after = authority[authority.index(after: close)...]
            guard !after.isEmpty else { return (authority[...close], nil) }
            guard after.hasPrefix(":"), let port = validPort(after.dropFirst()) else { return nil }
            return (authority[...close], port)
        }
        guard authority.filter({ $0 == ":" }).count == 1,
              let colon = authority.firstIndex(of: ":")
        else { return (authority, nil) }
        guard let port = validPort(authority[authority.index(after: colon)...]) else { return nil }
        return (authority[..<colon], port)
    }

    private static func validPort(_ text: Substring) -> Int? {
        guard let port = Int(text), (1...65535).contains(port) else { return nil }
        return port
    }
}
