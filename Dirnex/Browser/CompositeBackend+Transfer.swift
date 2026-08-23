import DirnexCore
import Foundation

/// Where a byte copy's two ends decide **who moves the bytes** — the one question the pane's
/// routing backend has to answer that a single `VFSPath` cannot (docs/HISTORY.md ▸ After M19).
///
/// Every other verb here routes on one path and is a one-liner. A copy has two, on backends that
/// have never heard of each other, and three different answers depending on the pair: one backend
/// serving both ends, one serving an upload or a download, or **neither** — two remote accounts,
/// where the bytes have to come through this machine because nothing else can carry them.
extension CompositeBackend {
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        switch try transferRoute(from: source, to: destination) {
        case let .direct(mover):
            try mover.copyFile(
                at: source,
                to: destination,
                progress: progress,
                isCancelled: isCancelled
            )
        case let .staged(sourceBackend, destinationBackend):
            try RelayCopy.copyFile(
                from: .init(source, on: sourceBackend),
                to: .init(destination, on: destinationBackend),
                stagingRoot: Self.relayStagingRoot,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    /// How one file's bytes get from `source` to `destination`.
    enum TransferRoute {
        /// One backend can do the whole thing: a local copy, an upload, a download, or S3's
        /// server-side duplicate.
        case direct(any VFSBackend)
        /// Nothing can, so the bytes are staged on this disk between a download and an upload
        /// (``RelayCopy``).
        case staged(source: any VFSBackend, destination: any VFSBackend)
    }

    /// Decide the route. Internal so it can be asserted directly: the *decision* is what breaks
    /// silently, and it is testable with no network, while running either route is not.
    func transferRoute(from source: VFSPath, to destination: VFSPath) throws -> TransferRoute {
        // Both ends on one backend, and that backend can copy inside itself: hand it over whole.
        // This is the local disk (with its clone fast path above it) and an S3 bucket, whose
        // `x-amz-copy-source` keeps the bytes inside the service — the case where staging through
        // this machine would be an expensive way to do nothing.
        if source.backend == destination.backend {
            let owner = try backend(for: source)
            if owner.capabilities(for: source).contains(.internalCopy) { return .direct(owner) }
        }
        // One end on this disk. An upload is the destination backend's `put`; a download is the
        // source backend's `get`, which is also how an archive member reports that it cannot be
        // extracted this way.
        if source.backend == .local, destination.backend.acceptsUploads {
            return .direct(try backend(for: destination))
        }
        if destination.backend == .local { return .direct(try backend(for: source)) }
        // Two remote accounts — or one account with no copy verb of its own, which is SFTP and FTP
        // even when both ends are the same server. Neither backend can reach the other, so the
        // bytes come through here.
        if source.backend.isRemoteConnection, destination.backend.acceptsUploads {
            return .staged(
                source: try backend(for: source),
                destination: try backend(for: destination)
            )
        }
        // Anything left is a pair nobody serves (a copy *into* a browsed archive, say). Route it to
        // the source's owner unchanged, so the refusal is the one that names the real reason rather
        // than a staging failure standing in for it.
        return .direct(try backend(for: source))
    }

    /// The temp root a staged remote-to-remote copy writes its intermediate file beneath, alongside
    /// `RemoteFileCache`'s and `ArchiveExtractor`'s and purged at launch for the same reason: a
    /// crash mid-transfer would otherwise leave a whole file behind with nobody left to delete it.
    static var relayStagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DirnexRelay", isDirectory: true)
    }

    /// Remove whatever a previous run's staged copies left. Called once at launch, before anything
    /// can be transferring, so it can clear the whole root without racing a copy in flight.
    static func purgeTemporaries() {
        try? FileManager.default.removeItem(at: relayStagingRoot)
    }
}
