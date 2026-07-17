import Foundation

/// Reading a local file's cloud-provider sync attributes (PLAN.md §M6 "iCloud/provider sync
/// status"). `CloudItemAttributes` decides what they mean; this is only the read.
///
/// It touches the filesystem, so per §2 it lives in `DirnexCore` beside `FinderTagStorage` — the
/// other core service that reaches past `VFSBackend` to a local path. Every entry point is
/// synchronous and blocking, and the panel drives it off the main thread: one read was **measured at
/// ~24 µs** — over twice a tag's `getxattr` — which is ~2.5 s across a 100k-row directory, against
/// M1's 150 ms budget for opening one. So the badge is filled from a cache afterwards and never
/// folded into `LocalBackend.listDirectory`, exactly as the tags column is not.
///
/// **A fresh `URL` per read, always, and this is not a style preference.** `NSURL` caches resource
/// values on the instance: probing a live download by polling one `URL` object reported
/// `NotDownloaded` for 37 s after the file had finished arriving, while a fresh `URL` each poll saw
/// it flip in 700 ms. Every function here builds its own `URL` and throws it away; nothing may hold
/// one between reads (`removeAllCachedResourceValues()` is the alternative, and is easier to forget
/// than a local).
public enum CloudSyncStorage {
    /// Everything `CloudItemAttributes` needs, asked for in one call — a resource-value read is a
    /// round trip to the file provider, and asking for all nine at once costs the same as one.
    static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemHasUnresolvedConflictsKey,
        .ubiquitousItemDownloadingErrorKey,
        .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemIsExcludedFromSyncKey
    ]

    /// The sync attributes of a local file or directory.
    ///
    /// Only `.local` paths can be cloud items — an archive member or an SFTP file is not backed by a
    /// file provider — so those throw `.unsupported` rather than quietly answering "not a cloud
    /// item", which is a claim this cannot make about somebody else's volume.
    ///
    /// A file the system declines to answer for comes back as the all-defaults value, i.e. not a
    /// cloud item and therefore no badge. That is the honest reading: outside a provider's tree
    /// every one of these attributes is `nil`.
    public static func attributes(at path: VFSPath) throws -> CloudItemAttributes {
        try requireLocal(path)
        return attributes(forPOSIXPath: path.path)
    }

    /// Whether this directory belongs to a cloud provider at all — **the gate that keeps this
    /// feature free for everyone who isn't looking at a cloud folder.**
    ///
    /// One read (~24 µs) answers for the whole directory, so an ordinary folder of 100k rows skips
    /// 100k reads (~2.5 s) rather than performing them all to conclude nothing. This works because a
    /// cloud folder *is itself* a cloud item: probed, `~/Library/Mobile Documents` and every
    /// directory under it report `isUbiquitousItem == true`.
    ///
    /// The `~/Library/CloudStorage` clause is deliberate insurance and is **not** verified: that is
    /// where third-party providers (Dropbox, Google Drive, OneDrive) mount, none was installed to
    /// probe against, and the plan's own wording is "where available". If such a provider answers
    /// the per-file attributes but does not mark its directories ubiquitous, this keeps the badge
    /// working; if it marks neither, the scan runs once per folder visit and finds nothing, which
    /// costs a folder-sized read and no correctness.
    public static func isCloudDirectory(_ path: VFSPath) -> Bool {
        guard path.backend == .local else { return false }
        if attributes(forPOSIXPath: path.path).isUbiquitous { return true }
        return isUnderProviderRoot(path.path)
    }

    /// The read itself, on a raw POSIX path. Every optional collapses to the value that means
    /// "nothing to report" — the reader must never invent a transfer out of an unanswered question;
    /// `CloudItemAttributes` documents why `isUploaded` is the one that defaults to `true`.
    static func attributes(forPOSIXPath path: String) -> CloudItemAttributes {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: keys) else { return CloudItemAttributes() }
        return CloudItemAttributes(
            isUbiquitous: values.isUbiquitousItem ?? false,
            downloadingStatus: values.ubiquitousItemDownloadingStatus
                .flatMap { CloudDownloadingStatus(rawValue: $0.rawValue) },
            isDownloading: values.ubiquitousItemIsDownloading ?? false,
            isUploading: values.ubiquitousItemIsUploading ?? false,
            isUploaded: values.ubiquitousItemIsUploaded ?? true,
            hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts ?? false,
            hasDownloadingError: values.ubiquitousItemDownloadingError != nil,
            hasUploadingError: values.ubiquitousItemUploadingError != nil,
            isExcludedFromSync: values.ubiquitousItemIsExcludedFromSync ?? false
        )
    }

    /// Where macOS mounts third-party file providers. Resolved against the real home directory
    /// rather than hardcoded, so it holds for whoever is running.
    private static func isUnderProviderRoot(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/Library/CloudStorage/")
    }

    private static func requireLocal(_ path: VFSPath) throws {
        guard path.backend == .local else {
            throw VFSError.unsupported("Only local files can be cloud-provider items.")
        }
    }
}
