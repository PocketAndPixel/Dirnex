import Foundation

/// Reading a local file's cloud-provider sync attributes (PLAN.md §M6 "iCloud/provider sync
/// status"). `CloudItemAttributes` decides what they mean; this is only the read.
///
/// It touches the filesystem, so per §2 it lives in `DirnexCore` beside `FinderTagStorage` — the
/// other core service that reaches past `VFSBackend` to a local path. Every entry point is
/// synchronous and blocking, and the panel drives it off the main thread. So the badge is filled from
/// a cache afterwards and never folded into `LocalBackend.listDirectory`, exactly as the tags column
/// is not.
///
/// **The cost is two orders of magnitude apart depending on the file, and only the expensive case
/// matters.** Re-measured 2026-07-22 against live iCloud Drive and a streaming-mode Google Drive: a
/// read on an ordinary local file is ~29 µs, but a read on an item *inside* a File Provider domain is
/// **650–1000 µs warm** — it is a round trip to the provider, not a `stat`. The original ~24 µs
/// figure was measured on a non-cloud file and so described the one case the directory gate below
/// skips entirely. Budget on the real number: a 5000-row cloud folder is ~3–5 s of background
/// scanning, not 120 ms.
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
    /// One read answers for the whole directory, so an ordinary folder of 100k rows skips 100k reads
    /// rather than performing them all to conclude nothing — and since the per-row read inside a
    /// provider costs ~700 µs rather than the ~29 µs a local file does, this gate is worth far more
    /// than the original measurement suggested. It works because a cloud folder *is itself* a cloud
    /// item: probed, `~/Library/Mobile Documents` and every directory under it report
    /// `isUbiquitousItem == true`.
    ///
    /// **The `~/Library/CloudStorage` clause is now verified** (2026-07-22, against Google Drive —
    /// the first third-party provider installed here). It turns out to be belt-and-braces rather than
    /// load-bearing: a File Provider mount reports `isUbiquitousItem == true` on its own, so the
    /// attribute check above already opens the gate. The prefix stays as insurance for a provider
    /// that answers per-file attributes without marking its directories.
    ///
    /// **What the same probe found that no gate can fix: Google Drive in *mirror* mode has no sync
    /// status at all.** `My Drive` is then a symlink out to `~/My Drive`, whose files are ordinary
    /// local files outside any provider domain — every ubiquity key `nil`, no `SF_DATALESS`, no
    /// xattrs. Finder still badges them, via Google's own `FinderSync` extension, which only Finder
    /// hosts. So a mirror-mode user correctly sees no badges, and that is the honest answer rather
    /// than a gap: streaming mode is where the OS has something to report. Note the gate *does* open
    /// there (the symlink itself reports ubiquitous), so the scan runs and finds nothing — cheap,
    /// because those reads take the ~29 µs local-file path, not the provider round trip.
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
            downloadingError: classify(values.ubiquitousItemDownloadingError),
            uploadingError: classify(values.ubiquitousItemUploadingError),
            isExcludedFromSync: values.ubiquitousItemIsExcludedFromSync ?? false
        )
    }

    /// Hand an error's identity — not merely its existence — to the core, which decides whether it is
    /// a verdict on the file or the routine "server not available" iCloud attaches to every pending
    /// upload. See `CloudTransferError`.
    private static func classify(_ error: NSError?) -> CloudTransferError? {
        error.map { CloudTransferError(domain: $0.domain, code: $0.code) }
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
