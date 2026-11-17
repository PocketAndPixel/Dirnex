import Foundation

public extension LocationSource {
    /// Where a pinned folder lives, which is what its Favorites row and its Go ▸ Places item mark in
    /// the corner of a folder glyph.
    ///
    /// ``of(_:mounts:vaultMountPoints:home:isInternalVolume:)`` answers for a tab, which is always
    /// somewhere that lists, so the mount table as it is now is the right witness. A pin outlives its
    /// mount: Dirnex unmounts the shares it mounted on quit, a vault locks, a drive is unplugged, and
    /// the pin is then an ordinary path under `/Volumes` on the boot disk. The mark says where a pick
    /// will go, so it must not fall back to a plain folder just when the pin is furthest away.
    ///
    /// - A pin that recorded its share (``FavoriteEntry/serverEndpoint``) is on the network, mounted
    ///   or not.
    /// - A pin under `/Volumes/<name>` with nothing mounted there is in the saved vault of that volume
    ///   name if there is one, and otherwise on a drive that is not plugged in. A share pinned before
    ///   pins recorded theirs reads as a drive until a pick mounts it and records it
    ///   (``Favorites/recordShare(_:for:)``), because nothing on the pin tells the two apart.
    /// - Everything else is wherever ``of(_:mounts:vaultMountPoints:home:isInternalVolume:)`` puts it.
    ///
    /// Safe on the main thread for the reason `of` is. The one read it adds is `isSymlink` on
    /// `/Volumes/<name>`, and only once the mount table has said nothing is mounted there.
    static func ofPin(
        _ entry: FavoriteEntry,
        mounts: [MountTableEntry],
        vaultMountPoints: [String],
        vaultVolumeNames: [String],
        home: String = NSHomeDirectory(),
        isInternalVolume: (String) -> Bool = MountTable.isInternalVolume(at:),
        isSymlink: (String) -> Bool = isSymbolicLink
    ) -> LocationSource {
        if entry.serverEndpoint?.smbShare != nil { return .networkVolume }
        let source = of(
            entry.path,
            mounts: mounts,
            vaultMountPoints: vaultMountPoints,
            home: home,
            isInternalVolume: isInternalVolume
        )
        guard source == .folder,
              let volume = PinnedShare.unmountedVolume(
                  of: entry.path,
                  mounted: mounts,
                  isSymlink: isSymlink
              )
        else { return source }
        return vaultVolumeNames.contains(volume) ? .vault : .externalVolume
    }

    /// Whether `path` is a symbolic link, as `/Volumes/Macintosh HD` is.
    @usableFromInline
    internal static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
