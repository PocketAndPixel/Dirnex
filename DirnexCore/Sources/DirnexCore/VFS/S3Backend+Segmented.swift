import Foundation

/// Downloading one object over several connections at once (docs/HISTORY.md ▸ After M19).
///
/// The mirror image of the multipart upload next door, and it exists for the same measurement read
/// the other way: one transfer is one `curl` and therefore one TCP connection, and a link that gives
/// 0.98 MB/s on one gives 4.49 aggregate on eight. A 28,5 MB object took most of a minute to
/// preview because of it, which is what started this.
///
/// Three properties the orchestration has to hold:
///
/// - **Nothing is left behind.** Every segment lands in a directory of this download's own, removed
///   on every exit path including the throwing ones — and each piece is deleted the moment it has
///   been appended, so peak disk is the object plus one segment rather than the object twice
///   (``S3SegmentAssembly``).
/// - **A transport that cannot split the request still works.** The verb's default forwards to the
///   plain download, and this reads which of the two happened rather than inferring it
///   (``S3SegmentedDownload``).
/// - **The pieces are what they claim to be.** Assembly refuses a segment whose length is not its
///   range's, which is what catches a truncated transfer and an endpoint that ignores `Range`
///   before a wrong file reaches the user's disk.
///
/// **One thing is deliberately not defended against, and it is worth naming rather than leaving to
/// be discovered.** An object *overwritten while this runs* can serve one version to one segment and
/// another to the next, and — if it grew — every range is satisfiable, so the assembled file is the
/// new object truncated to the old length. No client can close that: S3 has no snapshot across
/// requests, and the alternative (conditioning every segment on an ETag) needs an identity the
/// caller does not have, since the size that starts this rides in from a listing rather than from a
/// probe. The single-stream path has the same exposure in a milder form — it fetches whichever
/// version answers — and both are bounded by how stale the pane's listing is.
extension S3Backend {
    /// Download `key` as `plan`'s ranges, at once, and join them into `localPath`.
    ///
    /// Returns the bytes moved, or **`nil`** when the pieces are not ranges at all and the caller
    /// must fetch the object in one stream instead. That is the endpoint answering a `Range` request
    /// with the whole object — a success, and not the thing that was asked for — and a `nil` rather
    /// than a throw because the older route produces the right file: an S3-compatible server that
    /// does not honour ranges should be slow here, not broken.
    ///
    /// A **refusal** is not that case and is thrown, mapped as any other response is: a 404 or a 403
    /// on a segment is the object's answer, and retrying it whole would only ask the same question
    /// again more slowly.
    func downloadInSegments(
        _ request: S3DownloadRequest,
        plan: S3DownloadPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-s3-segments-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // No scratch space is this machine's problem, not the object's — and it is recoverable
            // by the one-stream route, which needs none.
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let segments = plan.segments(under: directory)
        let outcome = try mapping(request.source) {
            try transport.downloadSegments(
                segments,
                of: request.key,
                to: request.localPath,
                progress: progress,
                isCancelled: isCancelled
            )
        }
        if isCancelled() { throw CancellationError() }

        switch outcome {
        case let .whole(response):
            // The transport had no way to split the request and has already produced the file.
            _ = try succeed(response, at: request.source)
            return response.bytesTransferred
        case let .segments(responses):
            return try join(segments, responses, of: request)
        }
    }

    /// Classify every segment's answer, then splice the pieces — or report that they are not pieces.
    ///
    /// The count check is the same one the upload batch makes and for the same reason: a transport
    /// that answered for a different set of segments cannot be reconciled with the plan, and
    /// pressing on would assemble a file out of whichever answers happened to line up.
    private func join(
        _ segments: [S3DownloadSegment],
        _ responses: [S3Response],
        of request: S3DownloadRequest
    ) throws -> Int64? {
        guard responses.count == segments.count else {
            throw VFSError.io(path: request.source, code: EIO)
        }
        for response in responses {
            if let service = Self.serviceError(from: response) {
                throw service.vfsError(for: request.source)
            }
        }
        // 206 is what a satisfied `Range` request answers. A 200 means the server sent the whole
        // object to every section, so these files are copies rather than pieces.
        guard responses.allSatisfy({ $0.status == 206 }) else { return nil }

        do {
            return try S3SegmentAssembly.assemble(segments, into: request.localPath)
        } catch {
            // A failed assembly is about this machine or about bytes that did not arrive, never
            // about S3 — which is why it is mapped here rather than left to read as a transfer
            // error. The partial destination goes with it: half a file under the object's own name
            // is the one outcome worse than no file.
            try? FileManager.default.removeItem(atPath: request.localPath)
            throw VFSError.io(path: request.source, code: EIO)
        }
    }
}
