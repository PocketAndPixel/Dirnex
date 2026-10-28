import Foundation

/// Downloading one file over several connections at once (PLAN.md §M32, after Slice 6).
///
/// S3's shape over HTTP (``S3Backend``'s `downloadInSegments`), with what S3 could not have: an
/// identity for the file. S3's version names its open exposure — an object overwritten while the
/// ranges are in flight can serve one version to one range and another to the next — and leaves it,
/// since its size comes from a listing with no tag beside it. Here every section carries `If-Match`
/// with the tag the file has right now, so a file that changes is refused range by range and never
/// spliced from two versions.
///
/// "Right now" costs one `Depth: 0` PROPFIND, paid only for a file the listing already said is
/// large. It gives the current size, which is what the ranges are cut from, and the tag, and it
/// proves the login before several connections present it at once, so a password changed on the
/// server costs one failed login here rather than one per range.
///
/// Every outcome but two ends in the single stream. A cancellation is the user's and is thrown, and
/// a stat the server refused is the file's own answer and is thrown, as the single stream would
/// throw it. The rest fall back, and which of them also latch is ``judge(_:)``'s.
extension WebDAVBackend {
    /// Download `source` as several ranges at once and join them into `localPath`, returning the
    /// bytes moved, or **`nil`** when the caller must download it in one stream instead.
    ///
    /// `nil` before anything is fetched for a file that is no longer large, or that has no strong
    /// tag to guard the ranges with: Apache's tag is weak for the second after a write (NOTES.md ▸
    /// curl (WebDAV)), and an unguarded split could splice two versions of a file somebody is
    /// writing, where the single stream reads one.
    func downloadInSegments(
        _ source: VFSPath,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let entry = try stat(at: source)
        guard entry.kind == .file,
              SegmentedDownloadPlan.isWorthwhile(totalSize: entry.byteSize, limits: .webdav),
              let entityTag = RemoteFileRevision(entry).preconditionTag,
              let plan = SegmentedDownloadPlan(totalSize: entry.byteSize, limits: .webdav)
        else { return nil }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-webdav-segments-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // No scratch space is this machine's problem, and the single stream needs none.
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let segments = plan.segments(under: directory)
        let outcome = try mapping(source) {
            try transport.downloadSegments(
                segments,
                of: WebDAVTaggedFile(backendPath: source.path, entityTag: entityTag),
                to: localPath,
                progress: progress,
                isCancelled: isCancelled
            )
        }
        if isCancelled() { throw CancellationError() }

        switch outcome {
        case let .whole(response):
            // The transport could not split the request and has already written the file.
            guard response.isSuccess else {
                throw Self.serviceError(response, method: .get).vfsError(for: source)
            }
            return response.bytesDownloaded
        case let .segments(answers):
            guard answers.count == segments.count, judge(answers) else { return nil }
            do {
                return try SegmentAssembly.assemble(segments, into: localPath)
            } catch {
                // Every section said 206 and a piece is not its range's length: a server whose
                // ranges cannot be trusted. Half a file under the real name is the one outcome worse
                // than none, and the single stream is about to write it properly.
                try? FileManager.default.removeItem(atPath: localPath)
                segmentation.recordWholeFileAnswer()
                return nil
            }
        }
    }

    /// Whether every section came back as its range, and if not, what that says about the server.
    ///
    /// - **Every one 206**: join them.
    /// - **Any 412**: the file changed between the stat and the ranges. Nothing about the server, so
    ///   no latch; the single stream fetches the file as it is now.
    /// - **Any 200**: the server answered a range with the whole file, every section a full copy,
    ///   which is worth never asking this connection again (``SegmentedDownloadSupport``).
    /// - **Anything else** — some refused, some unanswered, some never sent: latched only when the
    ///   server served some ranges and not the rest, which is what a cap on connections per client
    ///   looks like. A refusal of every range is the file's answer (deleted, say), and the single
    ///   stream reports it.
    private func judge(_ answers: [WebDAVBatchAnswer]) -> Bool {
        let statuses = answers.map { answer -> Int? in
            if case let .response(response) = answer { return response.status }
            return nil
        }
        if statuses.allSatisfy({ $0 == 206 }) { return true }
        if statuses.contains(412) { return false }
        if statuses.contains(200) {
            segmentation.recordWholeFileAnswer()
            return false
        }
        segmentation.recordFailure(served: statuses.filter { $0 == 206 }.count)
        return false
    }
}
