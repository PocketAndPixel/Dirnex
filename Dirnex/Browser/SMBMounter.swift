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

    /// The kernel's mount table, which names every share mounted, Finder's included. A seam for the
    /// tests, which stand a temporary folder in for a share Finder mounted.
    var mountTable: () -> [MountTableEntry] = { MountTable.current() }

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

    /// The share whose root `path` is, whoever mounted it: one this app mounted or reached in this
    /// session, as it was reached, and otherwise what the mount table says was mounted there, a whole
    /// share on an SMB server as the account it names (PLAN.md §M40 Slice 8). What `..` at a share's
    /// root goes up to the server's list with. `nil` for a mount of a folder inside a share, whose
    /// parent is not the list, and for anything that is not a share.
    ///
    /// The mount table is read with `MNT_NOWAIT` and asks no server anything, so this is safe on the
    /// main thread with a share that has stopped answering, as ``share(mountedAt:)`` is.
    func shareRoot(at path: String) -> SMBLocation? {
        if let share = share(mountedAt: path) { return share }
        let entry = mountTable().first { $0.mountPoint == path }
        guard let source = entry.flatMap(SMBMountSource.init(entry:)), source.isWholeShare else {
            return nil
        }
        return source.share
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
    /// Matches on the mount's source as ``SMBMountSource`` reads it, whose ``SMBMountSource/mounts(_:)``
    /// gives the rule. A share-less location can't be matched to a specific mount, so it always
    /// re-mounts.
    ///
    /// It compared the raw source until 2026-11-19, which Apple's SMB client writes percent-escaped
    /// (PLAN.md §M40 Slice 8), so a share called "My Share", mounted as `My%20Share`, was never found
    /// and its second Return asked NetFS again; and a mount of `media/Movies` matched a share called
    /// `Movies`. The mount table is read without waiting, where the `statfs` per volume it replaces
    /// asked each share's server for fresh numbers.
    private nonisolated static func existingMountPoint(for location: SMBLocation) -> URL? {
        guard location.share != nil else { return nil }
        let mount = MountTable.current().first { entry in
            SMBMountSource(entry: entry)?.mounts(location) == true
        }
        return mount.map { URL(fileURLWithPath: $0.mountPoint) }
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
