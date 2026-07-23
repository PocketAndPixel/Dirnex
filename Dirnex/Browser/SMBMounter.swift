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
        let outcome = await Task.detached(priority: .userInitiated) {
            Self.netfsMount(location, username: username, password: password)
        }.value

        guard outcome.status == 0, let mountPoint = outcome.mountPoint else {
            throw SMBMountError(status: outcome.status, host: location.host)
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
        // Never block on an interactive NetFS dialog — a wrong password should return an error.
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
        if let share = location.share { result += "/\(share)" }
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
struct SMBMountError: LocalizedError {
    let status: Int32
    let host: String

    var errorDescription: String? {
        switch status {
        case Int32(EAUTH), Int32(EACCES), Int32(EPERM):
            return String(
                localized: """
                Authentication failed. Check the username and password, or try a guest connection.
                """,
                comment: "SMB mount failure: the server rejected the credentials."
            )
        case Int32(ENOENT), Int32(ENODEV):
            return String(
                localized: "The share wasn’t found on “\(host)”. Check the share name.",
                comment: "SMB mount failure; %@ is the host name."
            )
        case Int32(EHOSTDOWN), Int32(EHOSTUNREACH), Int32(ETIMEDOUT), Int32(ECONNREFUSED):
            return String(
                localized: "Couldn’t reach “\(host)”. Check the address and that the server is online.",
                comment: "SMB mount failure: the host did not answer; %@ is the host name."
            )
        case Int32(ECANCELED):
            return String(
                localized: "The connection was cancelled.",
                comment: "SMB mount failure: the user cancelled the mount."
            )
        default:
            return String(
                localized: "Couldn’t mount the share (error \(status)).",
                comment: "SMB mount failure with no specific diagnosis; %lld is the errno."
            )
        }
    }
}
