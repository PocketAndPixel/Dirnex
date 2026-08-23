import DirnexCore
import Foundation

/// Where a byte copy's two ends decide **who moves the bytes** — the one question the pane's
/// routing backend has to answer that a single `VFSPath` cannot (docs/HISTORY.md ▸ After M19).
///
/// Every other verb here routes on one path and is a one-liner. A copy has two, on backends that
/// have never heard of each other, and three different answers depending on the pair: one backend
/// serving both ends, one serving an upload or a download, or **neither** — two remote accounts,
/// where the bytes have to come through this machine because nothing else can carry them.
///
/// One pair sits between those: **two S3 buckets on the same service**, which the service itself
/// will copy between (`x-amz-copy-source`) and which staging would move twice for nothing. That is
/// the route with a fallback rather than a promise — see ``TransferRoute/serverSide(_:)``.
extension CompositeBackend {
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try copyFile(
            at: source,
            to: destination,
            expectedSize: nil,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// The same routing, carrying the caller's size hint through to whoever moves the bytes.
    ///
    /// **Forwarding it is the one failure here with no symptom** (docs/HISTORY.md ▸ After M19). The app holds a
    /// composite, so a hint that stopped at this method would leave every download quietly
    /// inheriting the single-stream default — same rows, same bytes, same correctness, just slow.
    /// It is the `subtreeListing` shape docs/NOTES.md already records: an opt-in seam whose default
    /// is "do it the old way" reports nothing at all when nobody wires it up, so what a test has to
    /// separate is *routed* from *answered*.
    ///
    /// Every route gets it, including the staged one — a relayed copy out of a bucket is an ordinary
    /// download followed by an ordinary upload, and the download half should be split like any
    /// other. The server-side route is the one exception in effect rather than in code: S3 copies
    /// those bytes itself, so the hint reaches a backend that has no use for it, and it matters
    /// again only if that route is refused and the copy falls through to staging below.
    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        switch try transferRoute(from: source, to: destination) {
        case let .direct(mover):
            try mover.copyFile(
                at: source,
                to: destination,
                expectedSize: expectedSize,
                progress: progress,
                isCancelled: isCancelled
            )
        case let .serverSide(mover):
            do {
                try mover.copyFile(
                    at: source,
                    to: destination,
                    expectedSize: expectedSize,
                    progress: progress,
                    isCancelled: isCancelled
                )
            } catch is CancellationError {
                // Stopping is not a refusal, and staging a cancelled copy would spend the whole
                // file on work the user has just stopped. Redundant today — `RelayCopy` checks
                // cancellation before it stages anything, so removing this line changes no
                // observable behaviour and no test can see it — and kept because that is a fact
                // about the *other* function, which is not where this rule belongs.
                throw CancellationError()
            } catch {
                try stage(
                    source,
                    to: destination,
                    expectedSize: expectedSize,
                    progress: progress,
                    isCancelled: isCancelled
                )
            }
        case let .staged(sourceBackend, destinationBackend):
            try RelayCopy.copyFile(
                from: .init(source, on: sourceBackend),
                to: .init(destination, on: destinationBackend),
                stagingRoot: Self.relayStagingRoot,
                expectedSize: expectedSize,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    /// Move the bytes through this machine — the route that needs nothing of either end.
    private func stage(
        _ source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try RelayCopy.copyFile(
            from: .init(source, on: try backend(for: source)),
            to: .init(destination, on: try backend(for: destination)),
            stagingRoot: Self.relayStagingRoot,
            expectedSize: expectedSize,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// How one file's bytes get from `source` to `destination`.
    enum TransferRoute {
        /// One backend can do the whole thing: a local copy, an upload, a download, or S3's
        /// server-side duplicate **inside one bucket**.
        case direct(any VFSBackend)
        /// The service copies between two of its own buckets and the bytes never come here — with
        /// the staged route behind it, because this is the one route that can be refused for
        /// reasons neither side can see in advance. S3 caps `CopyObject` at 5 GiB (above it the
        /// service wants `UploadPartCopy`, which is not built), an S3-compatible endpoint need not
        /// offer a cross-bucket copy at all, and a bucket policy can allow the read through one
        /// connection and not through the other. Every one of those is recoverable by moving the
        /// bytes ourselves, so a failure here degrades instead of reporting.
        case serverSide(any VFSBackend)
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
        // Two buckets, one service: S3 reads the source itself, so staging would carry every byte
        // twice to produce a request it would have made anyway. What decides it is a name being
        // unambiguous rather than a backend being S3 — `acceptsServerSideCopy` is where that is
        // argued, and refusing a pair merely sends it down the staged route below.
        if let mover = serverSideCopier(from: source, to: destination) { return .serverSide(mover) }
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

    /// The connected bucket that can copy `source` into `destination` server-side, or `nil` when
    /// no such request exists.
    ///
    /// The **destination's** connection performs it — one `PUT`, signed once, with its credentials
    /// doing the reading — so that is the backend that has to be live; the source is named in a
    /// header rather than fetched, and its own connection is only needed if this route is refused
    /// and the bytes end up being staged. Everything else the pair has to satisfy is
    /// `S3Location.acceptsServerSideCopy(from:)`, which is core and tested.
    private func serverSideCopier(from source: VFSPath, to destination: VFSPath) -> S3Backend? {
        guard source.backend != destination.backend, // one bucket is `.direct` above
              source.backend.isS3, destination.backend.isS3,
              let origin = S3Location(backendID: source.backend),
              let mover = s3Backend(for: destination.backend),
              mover.location.acceptsServerSideCopy(from: origin)
        else { return nil }
        return mover
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
