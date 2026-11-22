import Foundation

/// What an SMB mount says it is, read from the kernel's mount table: the share, and the account it
/// was mounted as (PLAN.md §M40 Slice 8).
///
/// A share Finder mounted is unknown to Dirnex, which records only the mounts it made or reached
/// itself, so `..` at its root used to go to `/Volumes`. The mount table names it anyway, and asks no
/// server anything to do so: `//olegasd@nas/media` for `/Volumes/media` (measured 2026-11-19), the
/// same string `volumeURLForRemountingKey` answers with `smb:` in front.
///
/// **The source is a URL without its scheme, every part percent-escaped**, read from Apple's own
/// SMB client (`CreateSMBFromName` and `smb_dictionary_to_urlstring` in `lib/smb/parse_url.c`,
/// apple-oss-distributions/SMBClient), since no share here has a name that needs escaping:
///
/// - `//[domain;][user[:]@]host[:port]/share[/path]`. The user's own `@ : ; / ?` are escaped, so
///   the one literal `@` ends the account, and a literal `:` before it is a password, which the
///   client writes only when it is empty: a guest mount always, and an account with no password;
/// - a guest mount is the account `GUEST` with that empty password, and the client treats any
///   account spelled `guest`, in any case, as guest access (`smb_ctx_setuser`), so this does too;
/// - the share escapes everything URL-reserved, a space included (`My%20Share`), and a path below it
///   is a mount of a folder inside the share;
/// - the account is dropped when the whole URL would not fit in `MAXPATHLEN`, which reads here as a
///   guest, the one account a source without one can be tried as.
public struct SMBMountSource: Sendable, Equatable {
    /// The share, on its server, reached as the account the mount names, or as a guest.
    public let share: SMBLocation
    /// The folders below the share's root that were mounted, for a mount of a folder inside a share;
    /// empty for the whole share.
    public let folder: [String]

    public init(share: SMBLocation, folder: [String] = []) {
        self.share = share
        self.folder = folder
    }

    /// Whether this is a mount of a whole share, rather than of a folder inside one.
    public var isWholeShare: Bool { folder.isEmpty }

    /// The account Apple's client takes as guest access (`kGuestAccountName`), compared without case.
    static let guestAccount = "guest"

    /// Read a mount table entry, or `nil` for anything that is not an SMB share's mount.
    public init?(entry: MountTableEntry) {
        guard entry.fileSystemType == "smbfs", !entry.isLocal else { return nil }
        self.init(source: entry.source)
    }

    /// Read an `smbfs` mount's source, `//olegasd@nas/media`, or `nil` when it names no share.
    public init?(source: String) {
        guard source.hasPrefix("//") else { return nil }
        let body = source.drop { $0 == "/" }
        let authority = body.prefix { $0 != "/" }
        let path = body.dropFirst(authority.count).split(separator: "/").map {
            Self.decoded($0)
        }
        guard let shareName = path.first, !shareName.isEmpty else { return nil }

        var hostPort = authority
        var username: String?
        if let at = authority.lastIndex(of: "@") {
            hostPort = authority[authority.index(after: at)...]
            // A literal `:` is only ever the password's, since the account's own is escaped.
            let account = Self.decoded(authority[..<at].prefix { $0 != ":" })
            let isGuest = account.caseInsensitiveCompare(Self.guestAccount) == .orderedSame
            username = account.isEmpty || isGuest ? nil : account
        }
        guard let (host, port) = Self.hostAndPort(hostPort) else { return nil }
        self.init(
            share: SMBLocation(host: host, share: shareName, username: username, port: port),
            folder: Array(path.dropFirst())
        )
    }

    /// Whether this mount is `location`'s share, so a connect can reuse it rather than ask NetFS
    /// again, which answers a share already mounted with `EEXIST` and no mount point.
    ///
    /// The account is not compared: a share is mounted once whoever mounted it, and that mount is
    /// the one there is. The share and the port must match exactly (the share without case, as SMB
    /// compares names), and only a whole share counts, so a mount of `media/Movies` is not a share
    /// called `Movies`. The host is matched loosely, as it always was: the typed name has to appear
    /// in the mounted one, since Finder's sidebar mounts a Bonjour service name such as
    /// `nas._smb._tcp.local` for a server typed as `nas`.
    public func mounts(_ location: SMBLocation) -> Bool {
        guard isWholeShare, let wanted = location.share, share.port == location.port,
              share.share?.caseInsensitiveCompare(wanted) == .orderedSame
        else { return false }
        return share.host.lowercased().contains(location.host.lowercased())
    }

    /// `host[:port]`, where the host may be an IPv6 literal in brackets, which keeps its brackets.
    private static func hostAndPort(_ text: Substring) -> (String, Int)? {
        var host = text
        var port = SMBLocation.defaultPort
        let hostEnd = text.hasPrefix("[") ? text.firstIndex(of: "]").map(text.index(after:)) : nil
        let search = text[(hostEnd ?? text.startIndex)...]
        if let colon = search.lastIndex(of: ":") {
            let tail = text[text.index(after: colon)...]
            guard let number = Int(tail), !tail.isEmpty else { return nil }
            host = text[..<colon]
            port = number
        }
        let decoded = decoded(host)
        return decoded.isEmpty ? nil : (decoded, port)
    }

    /// One part with its escapes undone, or as written when it holds an escape that does not decode,
    /// since a name read as written is better than none.
    private static func decoded(_ part: Substring) -> String {
        part.removingPercentEncoding ?? String(part)
    }
}
