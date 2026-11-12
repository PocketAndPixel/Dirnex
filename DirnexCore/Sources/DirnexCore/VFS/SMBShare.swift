import Foundation

/// One shared folder an SMB server offers, as its share list names it (PLAN.md §M35).
///
/// `name` is what a mount URL carries after the host, so it is what a row is called and what Return
/// on that row mounts. `comment` is the server's own description (`NetCommentStr`), often empty.
public struct SMBShare: Sendable, Hashable {
    public let name: String
    public let comment: String

    public init(name: String, comment: String = "") {
        self.name = name
        self.comment = comment
    }
}

/// The non-hermetic boundary beneath an ``SMBServerBackend``: open a session to one server and list
/// its shares.
///
/// The app's implementation drives the SMB plugin's `NetFSMountInterface_V1`, which this package
/// cannot import (docs/NOTES.md ▸ SMB). One call is one session, opened and closed again, since the
/// plugin's session is not something a `Sendable` value can hold across threads.
///
/// **A listing comes only from a session that opened.** Measured 2026-11-04 against the NAS: after a
/// guest `OpenSession` answered `-5999`, `EnumerateShares` on the same session answered 0 and listed
/// the shares as an account nobody had asked for (`home` read "Home directory of olegasd"), and it did
/// the same with no `OpenSession` at all. So an implementation throws when the session does not open,
/// and never lists after that.
public protocol SMBShareEnumerating: Sendable {
    /// The server's shares, or a throw of ``SMBShareListingError`` with the status that stopped it.
    func shares() throws -> [SMBShare]
}

/// Why a share listing did not come back: the status of the step that failed.
///
/// The status is NetFS's, read the way `NetFSMountURLSync`'s is (`<NetFS/NetFS.h>`): positive for an
/// `errno`, negative for an OSStatus such as `ENETFSACCOUNTRESTRICTED` (-5999). So the app can word
/// it with the sentences it already has for a failed mount.
public struct SMBShareListingError: Error, Sendable, Equatable {
    public let status: Int32

    public init(status: Int32) {
        self.status = status
    }
}

public extension SMBShare {
    /// The shares in a plugin's `EnumerateShares` answer that a person can open, sorted by name.
    ///
    /// The answer is a dictionary keyed by share name, each value a dictionary of facts
    /// (`<NetFS/NetFS.h>`, "Dictionary keys for the dictionary for a sharepoint"). Left out:
    ///
    /// - a share marked hidden (`IsHidden`), or whose name ends in `$` — the SMB convention for a
    ///   share kept out of browse lists (`IPC$`, `C$`, `ADMIN$`). It can still be typed into the
    ///   Share field;
    /// - a printer (`PrinterShare`), and anything whose `NetShareTypeStr` is present and is not
    ///   `Disk`: there is nothing to mount.
    ///
    /// A value that is not a dictionary is skipped rather than trusted. `DisplayName` is not used: the
    /// header keeps it for AFP names holding a `/`, and the row has to carry the name a mount needs.
    static func shares(fromSharepoints sharepoints: [String: Any]) -> [SMBShare] {
        sharepoints.compactMap { name, value -> SMBShare? in
            guard let facts = value as? [String: Any], !name.isEmpty else { return nil }
            guard !name.hasSuffix("$") else { return nil }
            if facts[Key.isHidden] as? Bool == true { return nil }
            if facts[Key.printerShare] as? Bool == true { return nil }
            if let type = facts[Key.type] as? String, type != Key.diskType { return nil }
            return SMBShare(name: name, comment: facts[Key.comment] as? String ?? "")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The plugin's keys, spelled here because the core does not link NetFS. The first two are
    /// `kNetFSIsHiddenKey` and `kNetFSPrinterShareKey`; the share type and comment are the SMB
    /// plugin's own, seen in its answer (PLAN.md §M35).
    private enum Key {
        static let isHidden = "IsHidden"
        static let printerShare = "PrinterShare"
        static let type = "NetShareTypeStr"
        static let comment = "NetCommentStr"
        static let diskType = "Disk"
    }
}

/// What a mount's `ENOENT` means, once the server's share list has been asked (PLAN.md §M35).
///
/// A share this account may not use and a share that is not there come back from
/// `NetFSMountURLSync` as the same status (measured 2026-09-04, docs/NOTES.md ▸ SMB), so the status
/// alone can only hedge. The list tells them apart, because the server names a refused share to the
/// very account it refuses.
public enum SMBShareAbsence: Sendable, Equatable {
    /// The server lists the share to this account and still would not mount it.
    case notPermitted
    /// The server does not list it to this account. Said as "doesn't offer", which stays true on a
    /// server that hides from an account the shares it refuses.
    case notOffered
    /// No list could be had, so both readings stay open.
    case unknown

    /// Read `share` against `listing`, the shares the same account was offered, or `nil` when the
    /// list could not be had. Names compare without case, as SMB compares them.
    public static func reading(share: String, listing: [SMBShare]?) -> SMBShareAbsence {
        guard let listing else { return .unknown }
        let isListed = listing.contains { $0.name.caseInsensitiveCompare(share) == .orderedSame }
        return isListed ? .notPermitted : .notOffered
    }
}
