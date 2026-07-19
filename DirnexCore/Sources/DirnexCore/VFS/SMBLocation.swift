import Foundation

/// Where an SMB share lives: the coordinates of a network share on another Mac, PC, or NAS,
/// without any secret. Like `SFTPLocation`, the password never lives here — only what the app
/// resolves against the Keychain (or nothing at all, for a guest mount) — so an `SMBLocation` is
/// safe to serialize into a saved `ServerConnection` and hand around freely.
///
/// Unlike `SFTPLocation`, this does **not** address a `VFSBackend`: SMB is browsed the OS-native
/// way (PLAN.md §M5 "SMB rides the OS mounter, not a protocol backend"). The app mounts
/// `smb://user@host/share` with NetFS / `mount_smbfs`, and the existing `LocalBackend` browses the
/// resulting `/Volumes/…` tree — so this type is purely the *address* the user types or pastes and
/// the sidebar stores, plus the mount target it resolves to. Its canonical string is exactly the
/// URL Finder's ⌘K "Connect to Server" takes.
public struct SMBLocation: Sendable, Hashable, Codable {
    /// Hostname, IP address, or Bonjour name of the SMB server.
    public let host: String
    /// The share to mount (the first path component of the URL), or `nil` when the URL names only a
    /// host — a bare `smb://host` that mounts-on-connect or offers a share picker (PLAN.md §M5
    /// "a bare `smb://host` (share omitted) mounts-on-connect / offers a share picker").
    public let share: String?
    /// The account name to authenticate as, or `nil` for a guest / anonymous mount (blank user),
    /// supported for home NAS (PLAN.md §M5 "Guest/anonymous mounts (blank user) supported").
    public let username: String?
    /// TCP port the SMB server listens on; the protocol default is 445 and is left out of the URL.
    public let port: Int

    /// SMB's well-known port, used (and elided from the URL) when a location doesn't specify one.
    public static let defaultPort = 445

    public init(
        host: String,
        share: String? = nil,
        username: String? = nil,
        port: Int = SMBLocation.defaultPort
    ) {
        self.host = host
        // Normalize empties to nil so "no share" and "guest" each have a single representation —
        // the sidebar and the mounter branch on `nil`, not on `""`.
        self.share = share.flatMap { $0.isEmpty ? nil : $0 }
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
        self.port = port
    }
}

public extension SMBLocation {
    /// The scheme every SMB URL starts with — the one Finder's Connect to Server uses.
    static let scheme = "smb://"

    /// The canonical `smb://[user@]host[:port][/share]` URL: the string shown in the address field
    /// and stored by the sidebar. The default port is elided (matching Finder), a guest mount omits
    /// the `user@`, and a share-less location stops at the host.
    var url: String {
        var result = SMBLocation.scheme
        if let username { result += "\(username)@" }
        result += host
        if port != SMBLocation.defaultPort { result += ":\(port)" }
        if let share { result += "/\(share)" }
        return result
    }

    /// Parse a `smb://[user@]host[:port][/share]` URL — the Finder-⌘K form the address field takes
    /// (type or paste) — into editable coordinates, or `nil` when it isn't an SMB URL / is malformed.
    ///
    /// The username is taken up to the first `@`; the host up to the first `/` (a `:port` suffix on
    /// the host is split off only when the tail is all digits, so a hostname is never mangled); the
    /// share is the *first* path component after the host, so a deeper `…/share/sub/dir` still mounts
    /// the share (navigating into `sub/dir` happens after the mount, an app concern). A `DOMAIN;user`
    /// prefix and a bracketed IPv6 literal aren't split out yet — realistic LAN shares use a
    /// hostname/IP and a plain user, so those are later refinements, not correctness holes here.
    init?(url: String) {
        guard url.hasPrefix(SMBLocation.scheme) else { return nil }
        var body = Substring(url.dropFirst(SMBLocation.scheme.count))

        var username: String?
        if let atIndex = body.firstIndex(of: "@") {
            username = String(body[..<atIndex])
            body = body[body.index(after: atIndex)...]
        }

        // Everything up to the first slash is host[:port]; the remainder is the share path.
        let hostPort: Substring
        var share: String?
        if let slashIndex = body.firstIndex(of: "/") {
            hostPort = body[..<slashIndex]
            let rest = body[body.index(after: slashIndex)...]
            // Only the first path component is the share; deeper subpaths are navigated post-mount.
            let firstComponent = rest.prefix { $0 != "/" }
            share = firstComponent.isEmpty ? nil : String(firstComponent)
        } else {
            hostPort = body
        }

        // Split a trailing `:digits` off the host as the port; leave any other colon in the host.
        var host = String(hostPort)
        var port = SMBLocation.defaultPort
        if let colonIndex = hostPort.lastIndex(of: ":") {
            let tail = hostPort[hostPort.index(after: colonIndex)...]
            if !tail.isEmpty, let parsed = Int(tail) {
                host = String(hostPort[..<colonIndex])
                port = parsed
            }
        }

        guard !host.isEmpty else { return nil }
        self.init(host: host, share: share, username: username, port: port)
    }

    /// The Keychain service every SMB password is filed under (a generic-password item's service).
    static let keychainService = "com.dirnex.smb"

    /// The Keychain account key for this location's stored password: the scheme-less URL
    /// (`[user@]host[:port][/share]`). Stable and unique per share, so re-mounting the same share
    /// later finds the password the app saved the first time. Unused for a guest mount (no secret).
    var keychainAccount: String {
        String(url.dropFirst(SMBLocation.scheme.count))
    }
}
