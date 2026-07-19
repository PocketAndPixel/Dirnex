import Foundation

/// Where an `SFTPBackend` connects: the coordinates of a remote SSH/SFTP account, without any
/// secret. The password or key passphrase never lives here — only what the app resolves against
/// the Keychain (PLAN.md §M5 "keychain-stored credentials, key auth") — so a `SFTPLocation` is
/// safe to serialize into a tab, a bookmark, or a `VFSBackendID` and hand around freely.
///
/// It is the SFTP analogue of the on-disk path an `ArchiveBackend`'s id encodes: a `VFSPath`
/// under `sftp://user@host:port` names both *which account* and *which remote path*, and the
/// app's composite backend routes on it to the right connection.
public struct SFTPLocation: Sendable, Hashable, Codable {
    /// Hostname or IP address of the SSH server.
    public let host: String
    /// TCP port the SSH server listens on; the protocol default is 22.
    public let port: Int
    /// The remote account name to authenticate as.
    public let username: String

    /// SSH's well-known port, used when a location doesn't specify one.
    public static let defaultPort = 22

    public init(host: String, port: Int = SFTPLocation.defaultPort, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }
}

public extension SFTPLocation {
    /// The scheme every SFTP backend id and descriptor starts with.
    static let scheme = "sftp://"

    /// The stable, round-trippable descriptor stored inside a `VFSBackendID`:
    /// `sftp://user@host:port`. Always includes the port so decoding is unambiguous.
    var descriptor: String {
        "\(SFTPLocation.scheme)\(username)@\(host):\(port)"
    }

    /// The backend id that addresses this account.
    var backendID: VFSBackendID { VFSBackendID(descriptor) }

    /// Parse a `sftp://user@host:port` descriptor, or `nil` when it isn't one / is malformed.
    ///
    /// The username is taken up to the first `@`; the port up to the *last* `:`, so a host can
    /// itself be unusual, but a bracketed IPv6 literal isn't handled yet (realistic servers use
    /// a hostname — that edge is a later refinement, not a correctness hole here).
    init?(descriptor: String) {
        guard descriptor.hasPrefix(SFTPLocation.scheme) else { return nil }
        let body = descriptor.dropFirst(SFTPLocation.scheme.count)
        guard let atIndex = body.firstIndex(of: "@") else { return nil }
        let username = String(body[..<atIndex])
        let hostPort = body[body.index(after: atIndex)...]
        guard let colonIndex = hostPort.lastIndex(of: ":") else { return nil }
        let host = String(hostPort[..<colonIndex])
        guard let port = Int(hostPort[hostPort.index(after: colonIndex)...]),
              !username.isEmpty, !host.isEmpty else { return nil }
        self.init(host: host, port: port, username: username)
    }

    /// Recover the account a backend id addresses, or `nil` when the id isn't an SFTP id.
    init?(backendID: VFSBackendID) {
        self.init(descriptor: backendID.rawValue)
    }

    /// The Keychain service every SFTP password is filed under (a generic-password item's service).
    static let keychainService = "com.dirnex.sftp"

    /// The Keychain account key for this location's stored password: `user@host:port`. Stable and
    /// unique per account (the descriptor without the `sftp://` scheme), so re-connecting to the
    /// same server later finds the password the app saved the first time.
    var keychainAccount: String { "\(username)@\(host):\(port)" }
}

public extension VFSBackendID {
    /// The backend id addressing a remote SFTP account (`sftp://user@host:port`).
    static func sftp(_ location: SFTPLocation) -> VFSBackendID { location.backendID }

    /// The SFTP account this id addresses, or `nil` when it isn't an SFTP id.
    var sftpLocation: SFTPLocation? { SFTPLocation(backendID: self) }

    /// Whether this id addresses a remote SFTP account (vs. `.local`, `.search`, or `archive:`).
    var isSFTP: Bool { rawValue.hasPrefix(SFTPLocation.scheme) }
}
