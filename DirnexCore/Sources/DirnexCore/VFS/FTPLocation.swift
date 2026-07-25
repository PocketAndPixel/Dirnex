import Foundation

/// How an `FTPLocation` protects its connection — the one axis on which the three FTP dialects
/// differ, and the reason a location needs more than a host and a port to identify itself.
///
/// The distinction is not cosmetic: explicit and implicit FTPS reach the *same* server on
/// *different* ports with *different* handshakes, so a saved connection that lost this field would
/// reconnect to the wrong thing. It rides in the descriptor's scheme for exactly that reason.
public enum FTPSecurity: String, Sendable, Hashable, Codable, CaseIterable {
    /// No TLS: the control connection, the password on it, and the data are all cleartext.
    ///
    /// Dirnex connects when asked and does not nag afterwards, but it does not *default* here —
    /// the connect form opens on ``explicit`` and plain FTP is a switch the user flips, so the
    /// tradeoff is stated once, where it is actionable (PLAN.md §7, resolved 2026-07-25).
    case plain
    /// `AUTH TLS` on the ordinary control port — what "FTPS" means in practice, and what FileZilla
    /// spells `ftpes://`. The connection opens in the clear and is upgraded before the password.
    case explicit
    /// TLS from the first byte on a dedicated port. Older and rarer than ``explicit``, but still
    /// what a good deal of NAS firmware offers, and free to support: it is a URL scheme to `curl`.
    case implicit

    /// The port a server of this kind listens on unless the user says otherwise.
    public var defaultPort: Int {
        switch self {
        case .plain, .explicit: return 21
        case .implicit: return 990
        }
    }

    /// Whether the connection is protected by TLS at all — the gate on certificate trust, which is
    /// meaningless for ``plain``.
    public var usesTLS: Bool { self != .plain }

    /// The scheme this mode is spelled with inside a descriptor.
    ///
    /// Three schemes rather than PLAN.md §M13's original two, because two cannot round-trip three
    /// modes: `ftps://` is `curl`'s (and the RFC's) name for *implicit* FTPS, while the mode almost
    /// everyone actually means is explicit. `ftpes://` is FileZilla's spelling for it and is the
    /// form users recognize, so each mode gets an unambiguous token and a saved connection can
    /// never decode as the wrong one.
    public var scheme: String {
        switch self {
        case .plain: return "ftp://"
        case .explicit: return "ftpes://"
        case .implicit: return "ftps://"
        }
    }

    /// The mode a descriptor's scheme names, or `nil` when the prefix isn't an FTP scheme. Longest
    /// prefix wins, so `ftps://` is never mistaken for `ftp://` plus a stray `s`.
    static func matching(descriptor: String) -> FTPSecurity? {
        allCases
            .sorted { $0.scheme.count > $1.scheme.count }
            .first { descriptor.hasPrefix($0.scheme) }
    }
}

/// How the CLI-driven transport authenticates against an FTP server. Carries no secret, for the
/// same reason `SFTPAuthentication` doesn't: the password is resolved from the Keychain by the app
/// and fed to `curl` out-of-band through a `-K -` config file on **stdin** — never in `argv`, where
/// any `ps` would read it, and never on disk.
public enum FTPAuthentication: Sendable, Hashable, Codable {
    /// A named account; the password is supplied out-of-band, never held here.
    case password
    /// The conventional public login (`anonymous` plus an e-mail-shaped string as the password).
    /// Nothing is stored in the Keychain, so this is the one method that needs no secret at all —
    /// which is most of what public FTP actually is.
    case anonymous
}

/// Where an `FTPBackend` connects: the coordinates of a remote FTP account and the security mode it
/// speaks, without any secret. The password never lives here — only what the app resolves against
/// the Keychain — so an `FTPLocation` is safe to serialize into a tab, a bookmark, or a
/// `VFSBackendID` and hand around freely.
///
/// It is the FTP analogue of `SFTPLocation`, and deliberately the same shape: a `VFSPath` under
/// `ftpes://user@host:port` names both *which account* and *which remote path*, and the app's
/// composite backend routes on it to the right connection.
public struct FTPLocation: Sendable, Hashable, Codable {
    /// Hostname or IP address of the FTP server.
    public let host: String
    /// TCP port the server listens on; the default depends on ``security``.
    public let port: Int
    /// The remote account name to authenticate as (`anonymous` for the public login).
    public let username: String
    /// Whether and how the connection is protected by TLS.
    public let security: FTPSecurity

    /// The username the conventional public login uses.
    public static let anonymousUsername = "anonymous"

    public init(host: String, port: Int? = nil, username: String, security: FTPSecurity = .explicit) {
        self.host = host
        self.port = port ?? security.defaultPort
        self.username = username
        self.security = security
    }
}

public extension FTPLocation {
    /// The stable, round-trippable descriptor stored inside a `VFSBackendID`:
    /// `<scheme>user@host:port`. Always includes the port so decoding is unambiguous, and carries
    /// the security mode in its scheme so a saved connection can't come back as a different one.
    var descriptor: String {
        "\(security.scheme)\(username)@\(host):\(port)"
    }

    /// The backend id that addresses this account.
    var backendID: VFSBackendID { VFSBackendID(descriptor) }

    /// Parse a `<scheme>user@host:port` descriptor, or `nil` when it isn't one / is malformed.
    ///
    /// The username is taken up to the first `@`; the port up to the *last* `:`, matching
    /// `SFTPLocation` — a bracketed IPv6 literal isn't handled yet, the same acknowledged edge.
    init?(descriptor: String) {
        guard let security = FTPSecurity.matching(descriptor: descriptor) else { return nil }
        let body = descriptor.dropFirst(security.scheme.count)
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        let username = String(body[..<atIndex])
        let hostPort = body[body.index(after: atIndex)...]
        guard let colonIndex = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colonIndex])
        guard let port = Int(hostPort[hostPort.index(after: colonIndex)...]),
              !username.isEmpty, !host.isEmpty else { return nil }
        self.init(host: host, port: port, username: username, security: security)
    }

    /// Recover the account a backend id addresses, or `nil` when the id isn't an FTP id.
    init?(backendID: VFSBackendID) {
        self.init(descriptor: backendID.rawValue)
    }

    /// The URL handed to `curl`, which knows only two FTP schemes: `ftps://` means *implicit* TLS,
    /// and explicit TLS is `ftp://` plus `--ssl-reqd` (supplied by `FTPProcessArguments`). So the
    /// scheme here deliberately does **not** match ``descriptor``'s — the descriptor's job is to
    /// round-trip three modes, this one's is to say what `curl` understands.
    ///
    /// `remotePath` is appended as given; a directory must end in `/` or the server answers with the
    /// file of that name instead of a listing.
    func url(forRemotePath remotePath: String) -> String {
        let scheme = security == .implicit ? "ftps://" : "ftp://"
        let path = remotePath.hasPrefix("/") ? remotePath : "/\(remotePath)"
        return "\(scheme)\(host):\(port)\(path)"
    }

    /// The Keychain service every FTP password is filed under (a generic-password item's service).
    static let keychainService = "com.dirnex.ftp"

    /// The Keychain account key for this location's stored password: `user@host:port` prefixed by
    /// the security mode, so the same account reached over plain FTP and over FTPS keeps separate
    /// entries — they are separate trust decisions and may genuinely differ.
    var keychainAccount: String { "\(security.rawValue):\(username)@\(host):\(port)" }

    /// Whether this location uses the conventional public login rather than a named account.
    var isAnonymous: Bool { username == FTPLocation.anonymousUsername }
}

public extension VFSBackendID {
    /// The backend id addressing a remote FTP account (`ftp://`, `ftpes://` or `ftps://`).
    static func ftp(_ location: FTPLocation) -> VFSBackendID { location.backendID }

    /// The FTP account this id addresses, or `nil` when it isn't an FTP id.
    var ftpLocation: FTPLocation? { FTPLocation(backendID: self) }

    /// Whether this id addresses a remote FTP account, in any of the three security modes.
    var isFTP: Bool { FTPSecurity.matching(descriptor: rawValue) != nil }
}
