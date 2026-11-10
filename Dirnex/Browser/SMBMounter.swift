import AppKit
import DirnexCore
import DiskArbitration
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

    /// The share each mount point holds, for every mount this app resolved in this session, its own
    /// or one it found already there. What `..` at a share's root reads to go up to the server's
    /// shares (PLAN.md §M35); a share Finder mounted and Dirnex never connected is absent, so `..`
    /// there still goes to `/Volumes`.
    private var mountedShares: [String: SMBLocation] = [:]

    /// Whether `path` is a network mount right now, read from the kernel's mount table, which asks no
    /// server anything. A seam for the tests, which stand a temporary folder in for a mount.
    var isNetworkMount: (String) -> Bool = { path in
        MountTable.current().contains { $0.mountPoint == path && !$0.isLocal }
    }

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
            record(location, mountedAt: existing.path)
            return existing
        }
        // Both panes can come back inside one share and ask for it at the same moment, and the
        // second has no mount to find yet. It waits for the first one's answer rather than asking
        // NetFS for a share that is already on its way.
        if let inFlight = mountsInFlight[location] { return try await inFlight.value }
        let task = Task { try await self.mountWithNetFS(
            location,
            username: username,
            password: password
        ) }
        mountsInFlight[location] = task
        defer { mountsInFlight[location] = nil }
        return try await task.value
    }

    /// The mount each share being mounted right now will answer with.
    private var mountsInFlight: [SMBLocation: Task<URL, any Error>] = [:]

    /// The blocking NetFS call, as `mount` makes it. A seam for the tests, which count the calls and
    /// answer with a temporary folder.
    var netfsMount: @Sendable (SMBLocation, String?, String?) -> MountOutcome = { location, user, password in
        SMBMounter.netfsMount(location, username: user, password: password)
    }

    private func mountWithNetFS(
        _ location: SMBLocation,
        username: String?,
        password: String?
    ) async throws -> URL {
        let alreadyMounted = Self.mountedVolumePaths()
        let netfsMount = netfsMount
        let outcome = await BlockingWork.run { netfsMount(location, username, password) }

        guard outcome.status == 0, let mountPoint = outcome.mountPoint else {
            throw SMBMountError(status: outcome.status, location: location)
        }
        // Ours only if the mount didn't exist before we asked — NetFS can hand back a share
        // someone else (Finder, a prior session) mounted, and quit must not tear that one down.
        if !alreadyMounted.contains(mountPoint.path) {
            ownedMountPoints.insert(mountPoint.path)
        }
        record(location, mountedAt: mountPoint.path)
        return mountPoint
    }

    /// Remember that `share` is mounted at `path`. Internal so a test can record a mount it made up.
    func record(_ share: SMBLocation, mountedAt path: String) {
        mountedShares[path] = share
    }

    /// Forget a mount recorded at `path`. Only the tests need it, to put back what they made up.
    func forget(mountedAt path: String) {
        mountedShares[path] = nil
        ownedMountPoints.remove(path)
    }

    /// The share mounted at exactly `path`, when this app mounted or reached it in this session and
    /// it is still a network mount there. Read from the kernel's mount table, which asks no server
    /// anything, so it is safe on the main thread with a share that has stopped answering.
    ///
    /// The mount-table check is what keeps an ejected share from sending `..` to a server: a disk of
    /// the same name mounted at the same path later is a local mount, and answers `nil`.
    func share(mountedAt path: String) -> SMBLocation? {
        guard let share = mountedShares[path] else { return nil }
        return isNetworkMount(path) ? share : nil
    }

    /// The share `path` is on, as a pin records it (`PinnedShare`), when this app mounted or reached
    /// that share in this session and it is still mounted. By whole path components, so
    /// `/Volumes/media-1/x` is not on the share at `/Volumes/media`.
    func shareEndpoint(containing path: VFSPath) -> ServerEndpoint? {
        guard path.backend == .local else { return nil }
        let holding = mountedShares.keys.filter { path.path == $0 || path.path.hasPrefix($0 + "/") }
        return holding.max { $0.count < $1.count }.flatMap(share(mountedAt:)).map(ServerEndpoint.smb)
    }

    /// Where each of `server`'s shares is mounted, among the mounts this app reached in this session
    /// and still there — what a tab on the server's list spells its places inside a share through
    /// (`SMBShareMounts`, PLAN.md §M35).
    func mounts(of server: SMBLocation) -> SMBShareMounts {
        var mountPoints: [String: String] = [:]
        for (path, share) in mountedShares {
            guard share.server == server.server, let name = share.share, isNetworkMount(path) else {
                continue
            }
            mountPoints[name] = path
        }
        return SMBShareMounts(mountPoints)
    }

    /// Unmount every share this app mounted — called on quit so we don't leave our mounts behind,
    /// while leaving any Finder-mounted share exactly as the user had it. Each unmount is asked for
    /// and not waited on (`requestUnmount`), so quitting never waits on another process.
    func unmountOwnedMounts() {
        for path in ownedMountPoints {
            Self.requestUnmount(URL(fileURLWithPath: path))
        }
        ownedMountPoints.removeAll()
    }

    // MARK: - NetFS (off-main, no actor state)

    struct MountOutcome: Sendable {
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
        // No UI, ever, so a wrong password fails here instead of in NetAuthAgent's dialog. A
        // location with no share used to let the UI through for macOS's own share picker, which
        // raised a second dialog on failure and never said which share was picked. A server is
        // listed by Dirnex now (`SMBShareEnumerator`, PLAN.md §M35), so nothing mounts without a
        // share, and one that tries fails with a status rather than a window.
        openOptions[kNAUIOptionKey as String] = kNAUIOptionNoUI

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

    /// Ask DiskArbitration to unmount a share, and return without waiting for the answer.
    ///
    /// An unmount first waits for every process that registered to approve one, and a process that
    /// never answers holds it for DiskArbitration's whole timeout. Measured 2026-11-02: a wedged
    /// `PhotosReliveWidget` held unmounts on this Mac for 10.7 s each, and the
    /// `unmountAndEjectDevice` this used to call is synchronous, so quitting with a share mounted
    /// kept the window up under a spinning cursor for 10.9 s. The request outlives the process that
    /// made it (measured with an approver holding it for 5 s after the requester had exited), so
    /// quit can leave at once and the daemon finishes the unmount, or fails it, on its own. A share
    /// another app still has open stays mounted, as it did before: the unmount fails with `EBUSY`.
    /// A mount point that is no longer a volume has no disk, and so nothing to unmount.
    private nonisolated static func requestUnmount(_ mountPoint: URL) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(
                  kCFAllocatorDefault,
                  session,
                  mountPoint as CFURL
              )
        else { return }
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), nil, nil)
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
    /// The account may not sign in now: disabled, locked out, or a guest on a server with guest
    /// access off. `ENETFSACCOUNTRESTRICTED` in `<NetFS/NetFS.h>`; the NAS answered it to a guest
    /// session on 2026-11-04 although its server info said guests were supported.
    static let eNetFSAccountRestricted: Int32 = -5999

    let status: Int32
    /// Where the mount was aimed. The host is named in every sentence below; the share and the
    /// account are named only by `shareUnavailable`, the one status that cannot diagnose itself.
    let location: SMBLocation
    /// What the server's share list said about the share, when it was asked after an `ENOENT`
    /// (PLAN.md §M35). `.unknown` keeps the sentence that names both readings.
    var absence: SMBShareAbsence = .unknown

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
        // because the Share field was left blank, so there was nothing to open. A blank Share field
        // lists the server's shares now (PLAN.md §M35), which answers an empty list rather than this,
        // so it is kept for a server that answers a mount this way.
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
        case Self.eNetFSAccountRestricted: // -5999
            guard let username = location.username else {
                return String(
                    localized: "“\(host)” doesn’t allow guest access. Enter a username and password.",
                    comment: "SMB mount failure: the server refused a guest mount; %@ is the host name."
                )
            }
            return String(
                localized: """
                “\(username)” can’t sign in to “\(host)” right now. The account may be disabled, or \
                locked after too many failed attempts.
                """,
                comment: """
                SMB connect failure: the server refused the account itself, not its password; \
                %1$@ is the account name, %2$@ the host name.
                """
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
            if let share = location.share, let sentence = Self.shareAbsent(
                share: share,
                host: host,
                username: location.username,
                absence: absence
            ) {
                return sentence
            }
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

    /// The sentence for a share the server's list has spoken about, or `nil` when it has not and the
    /// status has to carry both readings (``shareUnavailable(share:host:username:)``).
    ///
    /// A listed share that will not mount is one this account may not use, and says so plainly. One
    /// that is not listed is one the server *doesn't offer* this account, which stays true on a server
    /// that hides from an account the shares it refuses, where "doesn't exist" would not.
    private static func shareAbsent(
        share: String,
        host: String,
        username: String?,
        absence: SMBShareAbsence
    ) -> String? {
        switch (absence, username) {
        case (.unknown, _):
            return nil
        case let (.notPermitted, username?):
            return String(
                localized: "“\(username)” doesn’t have permission to use “\(share)” on “\(host)”.",
                comment: """
                SMB mount failure: the server lists the shared folder to this account and refuses it; \
                %1$@ is the account name, %2$@ the share name, %3$@ the host name.
                """
            )
        case (.notPermitted, nil):
            return String(
                localized: "A guest connection doesn’t have permission to use “\(share)” on “\(host)”.",
                comment: """
                SMB guest mount failure: the server lists the shared folder and refuses it to guests; \
                %1$@ is the share name, %2$@ the host name.
                """
            )
        case let (.notOffered, username?):
            return String(
                localized: "“\(host)” doesn’t offer a shared folder named “\(share)” to “\(username)”.",
                comment: """
                SMB mount failure: the server's list of shared folders for this account has no such \
                name; %1$@ is the host name, %2$@ the share name, %3$@ the account name.
                """
            )
        case (.notOffered, nil):
            return String(
                localized: "“\(host)” doesn’t offer a shared folder named “\(share)” to guests.",
                comment: """
                SMB guest mount failure: the server's list of shared folders has no such name; \
                %1$@ is the host name, %2$@ the share name.
                """
            )
        }
    }

    /// The sentence for the one status that means two different things — the share is not there, or
    /// this account may not use it (see the `ENOENT` case above).
    ///
    /// Four whole sentences rather than one with an interpolated fragment: a fragment spliced into a
    /// localized sentence has to be pre-inflected to survive the case system of half the shipped
    /// languages (docs/NOTES.md ▸ Localization). Used when the server's list could not be had after
    /// the refusal (``shareAbsent(share:host:username:absence:)`` otherwise). The two sentences with
    /// no share were for macOS's own share picker, which never said what was picked; nothing mounts
    /// without a share since Dirnex lists a server itself (PLAN.md §M35), and they stay for a status
    /// that arrives without one.
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
