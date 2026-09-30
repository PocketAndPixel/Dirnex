import Foundation

/// What one download is about: which object, where it lands, the path that names it in an error,
/// and the size the caller already knew.
///
/// Bundled for the reason ``S3MultipartRequest`` is — every step of a download needs the same four
/// and none of them varies between steps, so spelling them out pushes each signature past the
/// parameter-count ceiling the moment a progress hook is added.
struct S3DownloadRequest {
    let key: String
    let localPath: String
    let source: VFSPath
    /// What the caller's own listing measured, or `nil` when nobody knows. Never a probe — see
    /// ``S3Backend/copyFile(at:to:expectedSize:progress:isCancelled:)``.
    let expectedSize: Int64?
}

/// Moving one object's bytes — the three directions an S3 bucket can serve, and the two shapes a
/// download can take (PLAN.md §M21; docs/HISTORY.md ▸ After M19).
///
/// Split out of `S3Backend` by concept when the segmented download arrived and the type reached
/// SwiftLint's `type_body_length`: the listing verbs answer "what is there", these move bytes, and
/// the write verbs next door change what is there. Nothing here decides *sizing* — that is
/// `SegmentedDownloadPlan`'s and `S3MultipartPlan`'s — and nothing here spawns anything, which is the
/// injected transport's.
extension S3Backend {
    /// Copy one object's bytes, in whichever of the three directions this bucket can serve.
    ///
    /// - **Down** (this bucket → local disk): a `curl` download, resuming from a partial.
    /// - **Up** (local disk → this bucket): a streamed `--upload-file`. The stream is what makes it
    ///   affordable — see ``S3ProcessArguments/upload(session:key:localPath:)``, where a 512 MiB
    ///   file measured 5.3 MB resident streamed against 1.08 GB buffered.
    /// - **Sideways** (this bucket → itself, or **another bucket on the same service**):
    ///   `x-amz-copy-source`, server-side. The bytes never leave S3, so nothing is downloaded and
    ///   re-uploaded to duplicate a file — and this is the direction `CopyEngine` walks a folder
    ///   move through, which is what keeps a recursive rename from costing the user the whole
    ///   tree's bandwidth twice.
    ///
    /// The cross-bucket case is the same request with a different bucket in the header, and what
    /// gates it is ``S3Location/acceptsServerSideCopy(from:)``: one signature reaches both ends
    /// only if they share an access key id, and a bucket *name* only means one thing within one
    /// service. A pair that fails either test is refused here — as is a copy to or from any other
    /// remote — because it would have to land on this machine in between, which is two operations
    /// wearing one name and not this backend's to schedule (the pane's routing backend stages
    /// those, `RelayCopy`).
    ///
    /// **A server-side copy is capped at 5 GiB by the service**, above which S3 wants
    /// `UploadPartCopy` — not built. A refusal is not fatal for the cross-bucket pair, since the
    /// caller falls back to staging; a same-bucket copy of such an object fails, as it always has.
    ///
    /// The whole object transfers as one `curl` invocation, so both `progress` and `isCancelled`
    /// have to reach inside it: the transport polls them while the bytes move
    /// (``S3Transport/upload(localPath:to:progress:isCancelled:)``).
    ///
    /// What arrives during the transfer is an estimate at one-per-cent resolution; what arrives at
    /// the end is exact. Each direction therefore reports the **remainder** once the transfer
    /// returns — the exact count less whatever was streamed — so the running bar is smooth and the
    /// figure it settles on is the byte count `curl` measured, never a rounded sum.
    public func copyFile(
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

    /// The same copy, told how big the file is (docs/HISTORY.md ▸ After M19).
    ///
    /// **The hint decides whether a download is split**, and it is a hint rather than a probe for a
    /// measured reason: a `HEAD` before every download is a full handshake — ~0.5 s to first byte
    /// for a small object, since every `curl` re-signs and re-connects — which would roughly double
    /// the latency of the small files Quick View fetches constantly, to answer a question that only
    /// matters above 8 MiB. Both real callers already hold the number from the listing they made
    /// (`CopyEngine`'s `entry.byteSize`, `RemoteFileCache`'s entry), so it costs no extra request
    /// anywhere; with no hint, behaviour is exactly what it was.
    ///
    /// It is deliberately consulted **only** for the download direction. An upload's fork is the
    /// local file's own size, which `uploadObject` reads for itself and which cannot be stale.
    public func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        // Spelled as explicit comparisons rather than a `switch` over the pair: `case (id, .local)`
        // reads as a tuple pattern and is one missing `let` away from binding instead of matching,
        // which would route every direction to whichever arm came first.
        if source.backend == id, destination.backend == .local {
            var streamed: Int64 = 0
            let transferred = try downloadObject(
                S3DownloadRequest(
                    key: S3Key.key(for: source),
                    localPath: destination.path,
                    source: source,
                    expectedSize: expectedSize
                ),
                progress: { delta in
                    streamed += delta
                    progress(delta)
                },
                isCancelled: isCancelled
            )
            if isCancelled() { throw CancellationError() }
            reportRemainder(of: transferred, streamed: streamed, to: progress)
        } else if source.backend == .local, destination.backend == id {
            // Reports its own deltas rather than returning a total for the tail below to report: a
            // multipart upload reports one per part, and a second report here would count every
            // byte of a large file twice.
            try uploadObject(
                localPath: source.path,
                key: S3Key.key(for: destination),
                at: destination,
                progress: progress,
                isCancelled: isCancelled
            )
        } else if source.backend == id, destination.backend == id {
            let transferred = try copyObjectServerSide(from: source, to: destination)
            if isCancelled() { throw CancellationError() }
            progress(transferred)
        } else if destination.backend == id,
                  let origin = S3Location(backendID: source.backend),
                  location.acceptsServerSideCopy(from: origin) {
            let transferred = try copyObjectServerSide(from: source, in: origin, to: destination)
            if isCancelled() { throw CancellationError() }
            progress(transferred)
        } else {
            throw VFSError.unsupported(.copyFile)
        }
    }

    /// Upload `localPath` to `key` — in one `PUT` when it fits, in parts when it does not.
    ///
    /// The fork is ``S3MultipartPlan/isWorthwhile(totalSize:)`` and it is a *policy* threshold well
    /// below the 5 GiB the service forces, because multipart buys a retry unit smaller than the file
    /// and a progress bar that moves; the reasoning is argued at
    /// ``S3MultipartLimits/multipartThreshold``.
    ///
    /// On the single-`PUT` path the byte count comes from the write-out's upload counter rather than
    /// from the local file's size, so a short write is visible as a short write instead of being
    /// reported as whatever size the file happened to have on disk.
    /// Internal rather than file-private: the conditional upload in `S3Backend+Conditional.swift`
    /// goes through it, and Swift's `private` does not cross files.
    ///
    /// **Both branches carry `condition`, and that they share this one fork is the point**
    /// (PLAN.md §M21 Slice 19). The precondition rides on a different request in each — the `PUT`
    /// itself when the file fits, the completion that publishes the object when it does not — so a
    /// caller deciding *where* to attach one would be a second copy of the size threshold, which is
    /// how the small and large paths would come to disagree about whether a save is guarded.
    func uploadObject(
        localPath: String,
        key: String,
        at destination: VFSPath,
        condition: S3WriteCondition = .unconditional,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard !key.isEmpty else { throw VFSError.unsupported(.copyFile) }

        let size = localFileSize(localPath)
        if S3MultipartPlan.isWorthwhile(totalSize: size) {
            // No plan means no number of parts can hold it — S3 stops at 5 TiB. Refused here, by
            // name, rather than offering the whole file and letting the server say `EntityTooLarge`
            // at the end of it.
            guard let plan = S3MultipartPlan(totalSize: size) else {
                throw VFSError.unsupported(
                    .objectTooLargeForStore(name: destination.lastComponent)
                )
            }
            _ = try uploadInParts(
                S3MultipartRequest(
                    localPath: localPath,
                    key: key,
                    destination: destination,
                    plan: plan
                ),
                condition: condition,
                progress: progress,
                isCancelled: isCancelled
            )
            return
        }

        var streamed: Int64 = 0
        let response = try conditionallyWrite(at: destination, condition: condition) {
            try transport.upload(
                localPath: localPath,
                to: key,
                condition: condition,
                progress: { delta in
                    streamed += delta
                    progress(delta)
                },
                isCancelled: isCancelled
            )
        }
        if isCancelled() { throw CancellationError() }
        reportRemainder(of: response.bytesTransferred, streamed: streamed, to: progress)
    }

    /// Close the gap between what was streamed while a transfer ran and what it really moved.
    ///
    /// Only ever forward, and only when there is something to say — the rule lives in
    /// ``TransferProgressTally``, which FTP and SFTP reconcile through as well, since three backends
    /// spelling out one arithmetic is how one of them ends up spelling it differently.
    func reportRemainder(of exact: Int64, streamed: Int64, to progress: (Int64) -> Void) {
        var tally = TransferProgressTally()
        tally.add(streamed)
        if let remainder = tally.remainder(against: exact) { progress(remainder) }
    }

    /// Duplicate one object inside this bucket without the bytes leaving S3.
    ///
    /// **It reports 0 bytes moved, deliberately.** A `CopyObjectResult` carries an ETag and a
    /// timestamp, not a length, so the only way to report a real number is to ask for the object's
    /// size — one extra round trip per file. On a folder move that is one more request per object
    /// on top of the copy and the delete: negligible in money and about **25 minutes** of pure
    /// latency on a 50 000-file prefix at a typical round trip, spent entirely on advancing a
    /// progress bar. Reporting the size without measuring it would be inventing the number.
    ///
    /// What that costs is small and worth naming: this method is reached only from an F5 within one
    /// bucket and from `CopyEngine`'s recursive walk, and in both the engine already knows each
    /// entry's size from the listing it made. So the *item* counter advances normally and the byte
    /// counter does not move for these copies. A direct single-file move never comes here at all —
    /// `CopyEngine.perform` tallies `entry.byteSize` itself when `moveItem` succeeds.
    ///
    /// `origin` is the bucket the source lives in, and `nil` means this one. A cross-bucket copy is
    /// the same request with that bucket in the header — but it goes through the *other* transport
    /// verb, because a transport that cannot name another bucket must refuse rather than fall back
    /// on its own (``S3Transport/copyObject(fromBucket:sourceKey:to:)``). Two connections can name
    /// the same bucket under different descriptors (a re-addressed endpoint), so the fork is on the
    /// bucket rather than on which argument arrived.
    private func copyObjectServerSide(
        from source: VFSPath,
        in origin: S3Location? = nil,
        to destination: VFSPath
    ) throws -> Int64 {
        let sourceKey = S3Key.key(for: source)
        let destinationKey = S3Key.key(for: destination)
        // No action named, for the reason `copyFile(from:to:)` sets out: a server-side copy needs
        // `s3:GetObject` on the source and `s3:PutObject` on the destination — and here the source
        // may be another bucket entirely, so the two are not even the same policy.
        _ = try write(at: destination, action: nil) {
            if let origin, origin.bucket != location.bucket {
                try transport.copyObject(
                    fromBucket: origin.bucket,
                    sourceKey: sourceKey,
                    to: destinationKey
                )
            } else {
                try transport.copyObject(from: sourceKey, to: destinationKey)
            }
        }
        return 0
    }

    /// Download `key` to `localPath` — in several ranges at once when that is worth doing, in one
    /// stream when it is not.
    ///
    /// The fork has two conditions and each excludes a case the segmented path cannot serve. A
    /// **partial already on disk** takes the resuming route untouched, because segments are fetched
    /// into files of their own and have nothing to continue from; and no **size hint** means no
    /// plan, since asking for one would cost the round trip this feature exists to avoid. What is
    /// left is a fresh download of a known, worthwhile size, which is the ordinary case for the F5
    /// and the preview that started this.
    ///
    /// **The retry after a non-range answer reports nothing**, and that is the one subtlety worth
    /// stating: those segments really did land, and their bytes have already been handed to
    /// `progress`. Reporting them again would count one file twice in a job total that only adds,
    /// leaving a queue's bar permanently ahead of the work. The tail in ``copyFile`` still tops the
    /// count up to whatever the stream actually moved, so an object that turned out larger is not
    /// under-reported either.
    private func downloadObject(
        _ request: S3DownloadRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let existingLocal = localFileSize(request.localPath)
        if existingLocal == 0,
           let hint = request.expectedSize,
           SegmentedDownloadPlan.isWorthwhile(totalSize: hint, limits: .s3),
           !segmentation.isRefused,
           let plan = SegmentedDownloadPlan(totalSize: hint, limits: .s3) {
            if let moved = try downloadInSegments(
                request,
                plan: plan,
                progress: progress,
                isCancelled: isCancelled
            ) {
                return moved
            }
            return try downloadWholeObject(
                request,
                resume: false,
                progress: { _ in },
                isCancelled: isCancelled
            )
        }
        return try downloadWholeObject(
            request,
            resume: existingLocal > 0 && remoteSize(ofKey: request.key) > existingLocal,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// One `curl`, the whole object, resuming from a local partial when asked to.
    ///
    /// The caller decides whether to resume, and the remote size is checked there rather than left
    /// to `curl -C -` to discover: measured against a real bucket 2026-08-12, resuming onto an
    /// already-complete file answers **416 Range Not Satisfiable**, which this backend would
    /// correctly classify as a failed copy of a file that is in fact already there. `>`
    /// short-circuits, so a fresh download — the norm — never pays for the extra HEAD.
    private func downloadWholeObject(
        _ request: S3DownloadRequest,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        let response = try mapping(request.source) {
            try transport.download(
                key: request.key,
                to: request.localPath,
                resume: resume,
                progress: progress,
                isCancelled: isCancelled
            )
        }
        _ = try succeed(response, at: request.source)
        return response.bytesTransferred
    }

    /// The size of a local regular file, or 0 when it is absent or unreadable — which reads as "no
    /// partial", i.e. a full transfer.
    func localFileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// One object's size via a HEAD, or 0 when it cannot be read (missing or denied → no resumable
    /// partial, so the transfer starts from the beginning and reports the real failure itself).
    private func remoteSize(ofKey key: String) -> Int64 {
        guard let response = try? transport.head(key: key), response.isSuccess else { return 0 }
        return response.contentLength ?? 0
    }

    /// Everything in one bucket shares one endpoint and one credential, so all its jobs serialize
    /// (cheap, no I/O — as `VFSBackend.volumeIdentifier` requires).
    ///
    /// Conservative, and knowingly so: S3 is happy to serve many parallel requests, unlike an FTP
    /// server that caps logins. But the contract requires two paths on one "volume" to answer
    /// equal, and a bucket is the only unit this backend can name — so the choice is between
    /// serial-per-bucket and serial-for-everything (what `nil` means), and the former is the
    /// better of the two.
    public func volumeIdentifier(for path: VFSPath) -> String? {
        "s3://\(location.host):\(location.port)/\(location.bucket)"
    }
}
