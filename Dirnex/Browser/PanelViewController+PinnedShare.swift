import DirnexCore
import Foundation

/// A pin inside a network share that is not mounted (`PinnedShare`): picking it mounts the share and
/// goes in, as picking a pin on a connected account reconnects it.
///
/// It is `SMBMounter`'s ordinary mount, with no UI and the password the app already holds, so it is
/// unmounted on quit like any other this app made.
extension PanelViewController {
    /// What trying a pin's shares came to.
    enum PinnedShareResult: Equatable {
        /// One of them mounted and the pinned folder is on it, here.
        case landed(VFSPath, share: SMBLocation)
        /// One of them mounted and the folder is not on it: it really has been moved or deleted.
        case folderGone
        /// None of them mounted. The sentence says why.
        case failed(String)
    }

    private struct FailedShareMount {
        let error: any Error
        let share: SMBLocation
        let password: String?
    }

    /// Mounts one share with its password, returning the mount point. A seam for the tests, whose
    /// stand-in answers with a temporary folder rather than reaching NetFS.
    typealias ShareMount = @MainActor (SMBLocation, String?) async throws -> URL

    /// The shares that could bring `entry` back, or none when its folder is not missing for want of
    /// a mount. Takes the saved servers rather than reading them, so a test does not read the
    /// developer's own (docs/NOTES.md ▸ Testing).
    static func sharesToMount(for entry: FavoriteEntry, saved: [ServerConnection]) -> [SMBLocation] {
        guard let volume = PinnedShare.unmountedVolume(
            of: entry.path,
            mounted: MountTable.current(),
            isSymlink: isSymlink
        ) else { return [] }
        return PinnedShare.candidates(for: entry, volume: volume, saved: saved)
    }

    /// Whether `path` is a symbolic link, as `/Volumes/Macintosh HD` is.
    nonisolated static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// Mount one of `shares` and open `entry` on it, with the pin's sidebar row spinning meanwhile.
    func openPinnedShare(_ entry: FavoriteEntry, from shares: [SMBLocation], inNewTab: Bool) {
        let row = entry.path.path
        // Every click on a sidebar row runs its action, so a double-click arrives here twice, and a
        // second mount of a share would fail against the first.
        guard let host = shares.first?.host, !SidebarRowActivity.shared.isWorking(row) else { return }
        SidebarRowActivity.shared.begin(row)
        let token = loadToken
        runConnect(host: host) { [self] in
            defer { SidebarRowActivity.shared.end(row) }
            let result = await mountPinnedShare(entry, from: shares)
            guard token == loadToken else { return .succeeded } // the pane moved on while we mounted
            return finishPinnedShare(entry, result, inNewTab: inNewTab)
        }
    }

    /// Try `shares` in order until one mounts. An account with no saved password is passed over
    /// rather than prompted for, as a restored connection is (docs/LOCATION-SUPPORT.md
    /// <sup>ii</sup>). When none mounts, the first refusal is the one reported, since the first
    /// share is the likeliest to be the pin's own.
    func mountPinnedShare(
        _ entry: FavoriteEntry,
        from shares: [SMBLocation],
        mount: ShareMount = { share, password in
            try await SMBMounter.shared.mount(share, username: share.username, password: password)
        }
    ) async -> PinnedShareResult {
        var firstFailure: FailedShareMount?
        for share in shares {
            let password = Self.storedPassword(forShare: share)
            if share.username != nil, password == nil { continue }
            do {
                let mountPoint = try await mount(share, password)
                let folder = PinnedShare.path(entry.path, onMountPoint: mountPoint.path)
                let isThere = await BlockingWork.run { Self.directoryExists(folder) }
                return isThere ? .landed(folder, share: share) : .folderGone
            } catch {
                firstFailure = firstFailure
                    ?? FailedShareMount(error: error, share: share, password: password)
            }
        }
        guard let firstFailure else { return .failed(Self.genericConnectError) }
        return await .failed(shareMountFailure(
            firstFailure.error,
            mounting: firstFailure.share,
            password: firstFailure.password
        ))
    }

    /// The password for a share, from its own Keychain item or its server's, which is where one
    /// reached from the server's list is filed. `nil` for a guest share, which has none.
    static func storedPassword(forShare share: SMBLocation) -> String? {
        guard share.username != nil else { return nil }
        return SecretKeychain.password(for: share) ?? SecretKeychain.password(for: share.server)
    }

    private func finishPinnedShare(
        _ entry: FavoriteEntry,
        _ result: PinnedShareResult,
        inNewTab: Bool
    ) -> ConnectServerPrompt.Attempt {
        switch result {
        case let .landed(folder, share):
            // An older pin keeps what its first mount showed, so the next one needs no search.
            var favorites = FavoritesStore.load()
            if favorites.recordShare(share, for: entry.path) { FavoritesStore.save(favorites) }
            navigate(to: folder, inNewTab: inNewTab)
            return .succeeded
        case .folderGone:
            presentMissingFavoriteEntry(entry.path)
            return .succeeded
        case let .failed(detail):
            return .failed(detail)
        }
    }
}
