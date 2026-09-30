import AppKit
import DirnexCore
import Foundation
import NetFS

/// Mounts SMB shares the OS-native way and tracks which mounts are *ours* (PLAN.md §M5 "SMB rides
/// the OS mounter, not a protocol backend"). macOS ships no `smbclient` to shell out to, so the
/// sidestep for SMB is the *mounter*: `NetFSMountURLSync` mounts `smb://user@host/share` into
/// `/Volumes/…`, and the existing `LocalBackend` browses that tree — so every M2 op, sync-dirs,
/// compare-by-content, and archive-over-SMB works unchanged.
///
/// The one genuinely new surface is the mount *lifecycle*, which lives here (the non-hermetic I/O
/// boundary, like `ArchiveMounter`): mount on connect, and unmount only what *we* mounted on
/// quit — a share the user already mounted in Finder is left alone. `shared` is the
/// app-wide registry so quit can tear our mounts down.
@MainActor
final class SMBMounter {
    static let shared = SMBMounter()

    /// Mount points (`/Volumes/…` paths) this app created, so `unmountOwnedMounts()` (on quit)
    /// only ever unmounts ours. A share that was already mounted when we connected —
    /// by Finder, or a prior connect — is deliberately absent, so we never eject someone else's mount.
    private var ownedMountPoints: Set<String> = []

    /// Mount `location`, returning the `/Volumes/…` mount point. A `nil`/empty `username` mounts as
    /// guest; otherwise `password` authenticates (a `nil` password means "empty password"). The
    /// blocking NetFS call runs off-main; the registry update happens back on the main actor.
    ///
    /// If the share is already mounted (Finder, or an earlier connect), we detect and reuse that
    /// mount point rather than re-mounting, recording it as ours only if we were the ones who
    /// mounted it — so quit leaves someone else's mount in place.
    func mount(_ location: SMBLocation, username: String?, password: String?) async throws -> URL {
        // If this exact share is already mounted — by Finder, or an earlier connect — reuse that
        // mount instead of asking NetFS again (which returns EEXIST with no mount point).
        if let existing = Self.existingMountPoint(for: location) {
            return existing
        }

        let alreadyMounted = Self.mountedVolumePaths()
        let outcome = await BlockingWork.run {
            Self.netfsMount(location, username: username, password: password)
        }

        guard outcome.status == 0, let mountPoint = outcome.mountPoint else {
            throw SMBMountError(status: outcome.status, location: location)
        }
        // Ours only if the mount didn't exist before we asked — NetFS can hand back a share
        // someone else (Finder, a prior session) mounted, and quit must not tear that one down.
        if !alreadyMounted.contains(mountPoint.path) {
            ownedMountPoints.insert(mountPoint.path)
        }
        return mountPoint
    }

    /// Unmount every share this app mounted — called on quit so we don't leave our mounts behind,
    /// while leaving any Finder-mounted share exactly as the user had it.
    func unmountOwnedMounts() {
        for path in ownedMountPoints where Self.unmount(URL(fileURLWithPath: path)) {
            // Removal happens after the loop so we don't mutate the set mid-iteration.
        }
        ownedMountPoints.removeAll()
    }

    // MARK: - NetFS (off-main, no actor state)

    private struct MountOutcome {
        let status: Int32
        let mountPoint: URL?
    }

    /// The blocking NetFS mount. Builds a user-less `smb://host[:port]/share` URL and supplies the
    /// credentials separately (the canonical NetFS usage), suppresses any UI prompt so a bad
    /// password fails fast instead of blocking on a dialog, and returns the first mount point NetFS
    /// reports. Runs on a detached task — no main-actor state is touched here.
    private nonisolated static func netfsMount(
        _ location: SMBLocation,
        username: String?,
        password: String?
    ) -> MountOutcome {
        guard let url = URL(string: mountURLString(for: location)) else {
            return MountOutcome(status: Int32(EINVAL), mountPoint: nil)
        }

        let openOptions = NSMutableDictionary()
        // Suppress NetFS's interactive UI so a wrong password fails fast — *except* when no share was
        // named. There, letting the UI through is the whole point: `NetFSMountURLSync` on a bare
        // `smb://host` shows macOS's own share picker (the NetFS header: "the user will be prompted
        // with a window to let them select one or more items to mount"), which is how the user finds
        // a share they don't know the name of. Dirnex has no picker of its own *yet* — the shares can
        // be listed in-process (`EnumerateShares` on the SMB plugin's `NetFSMountInterface_V1`,
        // <NetFS/NetFSPlugin.h>, measured working against a real server 2026-09-04), and the cost of
        // not having one is that a failed pick can never be named: NetFS reports no share back, so
        // `SMBMountError` has to leave the folder unnamed (docs/NOTES.md ▸ SMB).
        openOptions[kNAUIOptionKey as String] = location.share == nil ? kNAUIOptionAllowUI
            : kNAUIOptionNoUI

        let user: CFString?
        let pass: CFString?
        if let username, !username.isEmpty {
            user = username as CFString
            pass = (password ?? "") as CFString
        } else {
            // Guest / anonymous mount (blank user), for a home NAS.
            openOptions[kNetFSUseGuestKey as String] = true
            user = nil
            pass = nil
        }

        var mountpoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            url as CFURL,
            nil, // default mount root (/Volumes)
            user,
            pass,
            openOptions as CFMutableDictionary,
            nil,
            &mountpoints
        )
        let paths = mountpoints?.takeRetainedValue() as? [String]
        let mountPoint = paths?.first.map { URL(fileURLWithPath: $0) }
        return MountOutcome(status: status, mountPoint: mountPoint)
    }

    /// The `smb://host[:port]/share` URL passed to NetFS — deliberately *without* the username, which
    /// is supplied to `NetFSMountURLSync` as a separate argument (mixing both is ambiguous).
    /// `internal` (not `private`) so the contract "the username never appears here" is unit-tested.
    nonisolated static func mountURLString(for location: SMBLocation) -> String {
        var result = "smb://\(location.host)"
        if location.port != SMBLocation.defaultPort { result += ":\(location.port)" }
        // Percent-encoded, unlike `SMBLocation.url`, which is the string the user typed and the
        // sidebar stores. This one is parsed by `URL(string:)`, which on macOS 14 — the
        // deployment target — is the strict parser and answers **nil** for a share name
        // holding a space or a non-ASCII character (``SMBLocation/percentEncodedShare(_:)``).
        if let share = location.share { result += "/\(SMBLocation.percentEncodedShare(share))" }
        return result
    }

    /// The mount point of `location`'s share if it's already mounted (by Finder or an earlier
    /// connect), else `nil` — so a re-connect reuses the mount instead of hitting NetFS's EEXIST.
    /// Matches on the volume's `f_mntfromname` (the smbfs source, `//[user@]host/share`): the host
    /// and share are compared case-insensitively, since SMB is case-insensitive. A share-less
    /// location can't be matched to a specific mount, so it always re-mounts.
    private nonisolated static func existingMountPoint(for location: SMBLocation) -> URL? {
        guard let share = location.share else { return nil }
        let host = location.host.lowercased()
        let shareSuffix = "/" + share.lowercased()
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        for url in urls {
            var info = statfs()
            guard statfs(url.path, &info) == 0 else { continue }
            let source = withUnsafeBytes(of: &info.f_mntfromname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            guard source.hasPrefix("//") else { continue } // an smbfs/network source
            let lowered = source.lowercased()
            if lowered.contains(host), lowered.hasSuffix(shareSuffix) { return url }
        }
        return nil
    }

    /// The paths of every currently-mounted volume — snapshotted before a mount so we can tell a
    /// share we mounted from one that was already there.
    private nonisolated static func mountedVolumePaths() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil,
            options: []
        ) ?? []
        return Set(urls.map(\.path))
    }

    /// Eject a network share (Finder's own disconnect gesture). Failures are swallowed — a busy
    /// share that won't unmount on quit isn't worth blocking termination over.
    @discardableResult
    private nonisolated static func unmount(_ mountPoint: URL) -> Bool {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: mountPoint)
            return true
        } catch {
            return false
        }
    }
}

/// A failed SMB mount, mapped from the NetFS/`errno` status into a human-readable reason.
///
/// `NetFSMountURLSync` returns a *positive* value for an `errno` and a *negative* value for an
/// OSStatus (documented in `<NetFS/NetFS.h>`). The negative NetAuth codes below aren't exported by
/// the NetFS module, so they're spelled out here with their symbolic names, exactly as that header
/// lists them.
struct SMBMountError: LocalizedError {
    /// No share was available to mount — the server was reached and authenticated, but named no
    /// share (blank Share field). `<NetAuth/NetAuthErrors.h>`.
    static let kNetAuthErrorNoSharesAvailable: Int32 = -6003
    /// The server refused a guest / anonymous mount. `<NetAuth/NetAuthErrors.h>`.
    static let kNetAuthErrorGuestNotSupported: Int32 = -6004
    /// The NetFS-layer spelling of "no shares available". `<NetFS/NetFS.h>`.
    static let eNetFSNoSharesAvail: Int32 = -5998
    /// The mount was canceled (Carbon `userCanceledErr`), the negative-OSStatus twin of `ECANCELED`.
    static let userCanceledErr: Int32 = -128

    let status: Int32
    /// Where the mount was aimed. The host is named in every sentence below; the share and the
    /// account are named only by `shareUnavailable`, the one status that cannot diagnose itself.
    let location: SMBLocation

    private var host: String { location.host }

    var errorDescription: String? {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            return String(
                localized: """
                Authentication failed. Check the username and password, or try a guest connection.
                """,
                comment: "SMB mount failure: the server rejected the credentials."
            )
        // A reachable, authenticated server that offered no share to mount comes back as a *negative*
        // OSStatus (from <NetFS/NetFS.h> and <NetAuth/NetAuthErrors.h>), not an errno — almost always
        // because the Share field was left blank, so there was nothing to open. A bare `smb://host`
        // can't pick a share without an interactive prompt, and Dirnex suppresses that prompt (so a
        // bad password fails fast instead of blocking), so there's no fallback share picker here.
        case Self.kNetAuthErrorNoSharesAvailable, // -6003
             Self.eNetFSNoSharesAvail: // -5998
            return String(
                localized: """
                Connected to “\(host)”, but couldn’t find a shared folder to open. Enter the name of a \
                folder shared on that computer in the Share field.
                """,
                comment: "SMB mount failure: authenticated but no share to mount; %@ is the host name."
            )
        case Self.kNetAuthErrorGuestNotSupported: // -6004
            return String(
                localized: "“\(host)” doesn’t allow guest access. Enter a username and password.",
                comment: "SMB mount failure: the server refused a guest mount; %@ is the host name."
            )
        // A share the account may not use and a share that isn’t there are the *same* status.
        // Measured 2026-09-04 against a real Synology: `NetFSMountURLSync` answers ENOENT for a share
        // the server refuses this account (`Photos`, `Movies`) and for one that does not exist
        // (`NoSuchShareXYZ`) alike, while a share the account may use mounts (status 0) and the same
        // refused share mounts for another account — so the code carries no permission signal at all
        // (docs/NOTES.md ▸ SMB, "a denied share and a missing share are one status"). The sentence
        // therefore has to carry both readings: "check the share name" alone sent a user whose account
        // simply lacked access hunting for a typo, and in the picker flow it named a Share field they
        // had deliberately left blank.
        case Int32(ENOENT), Int32(ENODEV):
            return Self.shareUnavailable(
                share: location.share,
                host: host,
                username: location.username
            )
        case Int32(EHOSTDOWN), Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ECONNREFUSED):
            return String(
                localized: "Couldn’t reach “\(host)”. Check the address and that the server is online.",
                comment: "SMB mount failure: the host did not answer; %@ is the host name."
            )
        case Int32(ECANCELED), Self.userCanceledErr: // -128
            return String(
                localized: "The connection was canceled.",
                comment: "SMB mount failure: the user canceled the mount."
            )
        default:
            return String(
                localized: "Couldn’t mount the share (error \(status)).",
                comment: "SMB mount failure with no specific diagnosis; %lld is the errno."
            )
        }
    }

    /// The sentence for the one status that means two different things — the share is not there, or
    /// this account may not use it (see the `ENOENT` case above).
    ///
    /// Four whole sentences rather than one with an interpolated fragment: a fragment spliced into a
    /// localized sentence has to be pre-inflected to survive the case system of half the shipped
    /// languages (docs/NOTES.md ▸ Localization). The share is absent exactly when the user left the
    /// Share field blank and picked a folder from macOS’s own share picker, which never tells us what
    /// they picked — hence the folder going unnamed there rather than being named wrongly.
    private static func shareUnavailable(share: String?, host: String, username: String?) -> String {
        switch (share, username) {
        case let (share?, username?):
            return String(
                localized: """
                Couldn’t open “\(share)” on “\(host)”. That shared folder may not exist, or \
                “\(username)” may not have permission to use it.
                """,
                comment: """
                SMB mount failure; %1$@ is the share name, %2$@ the host name, %3$@ the account name.
                """
            )
        case let (share?, nil):
            return String(
                localized: """
                Couldn’t open “\(share)” on “\(host)”. That shared folder may not exist, or a guest \
                connection may not have permission to use it.
                """,
                comment: "SMB guest mount failure; %1$@ is the share name, %2$@ the host name."
            )
        case let (nil, username?):
            return String(
                localized: """
                The shared folder couldn’t be opened on “\(host)”. It may not exist, or “\(username)” \
                may not have permission to use it.
                """,
                comment: """
                SMB mount failure, folder chosen in macOS’s share picker so its name is unknown; \
                %1$@ is the host name, %2$@ the account name.
                """
            )
        case (nil, nil):
            return String(
                localized: """
                The shared folder couldn’t be opened on “\(host)”. It may not exist, or a guest \
                connection may not have permission to use it.
                """,
                comment: """
                SMB guest mount failure, folder chosen in macOS’s share picker; %@ is the host name.
                """
            )
        }
    }
}
