import Foundation

/// Downloading one remote file over several logins at once (docs/HISTORY.md ▸ After M19).
///
/// The S3 half's twin, built after it and deliberately not a copy of it: the *shape* is the same
/// (one `curl -Z`, N sections on stdin, pieces joined by ``SegmentAssembly``) and everything about
/// **how a run is judged** is different, because FTP tells a client far less. Measured 2026-08-24
/// against a real server:
///
/// - A section's reply code is a race — `225` and `226` came back mixed across the *successful*
///   sections of one run, since a range download closes the data connection early — and a failed
///   section reports `221`, the goodbye. One `curl` carrying N transfers has **one** exit code.
///   So there is no per-section classification to read, and the pieces on disk are the evidence.
/// - A server that **caps concurrent connections** does not degrade, it fails the run: with a cap
///   of 2 and eight sections, two completed and six were refused `421`. That is the commonest
///   reason this can fail, it is invisible to the user, and no error message would help them — so
///   any failure falls back to a single stream rather than being reported.
/// - The fallback is not free, which is why the connection remembers. Those two completed sections
///   were a quarter of the file, downloaded and thrown away; without a latch that price is paid
///   again for every file (``SegmentedDownloadSupport``).
extension FTPBackend {
    /// Download `remotePath` as `plan`'s ranges, at once, and join them into `localPath`.
    ///
    /// Returns the bytes moved, or **`nil`** when the caller must fetch the file in one stream
    /// instead — which is every failure except a cancellation. A cancellation is the user's decision
    /// and is re-thrown: retrying what somebody just stopped is the one fallback that is never
    /// wanted.
    func downloadInSegments(
        _ request: FTPDownloadRequest,
        plan: SegmentedDownloadPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-ftp-segments-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // No scratch space is this machine's problem, not the server's — and it is recoverable
            // by the one-stream route, which needs none.
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let segments = plan.segments(under: directory)
        do {
            let outcome = try mapErrors(request.source) {
                try transport.downloadSegments(
                    segments,
                    of: request.remotePath,
                    to: request.localPath,
                    progress: progress,
                    isCancelled: isCancelled
                )
            }
            if isCancelled() { throw CancellationError() }
            switch outcome {
            case let .whole(bytes):
                // The transport had no way to split the request and has already produced the file.
                return bytes
            case .segments:
                return try SegmentAssembly.assemble(segments, into: request.localPath)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Half a file under the real name is the one outcome worse than no file, and the
            // single-stream retry is about to write it properly anyway.
            try? FileManager.default.removeItem(atPath: request.localPath)
            segmentation.recordFailure(served: Self.served(segments))
            return nil
        }
    }

    /// How many of this run's pieces the server actually wrote — the evidence the latch weighs.
    ///
    /// A file that is *present but the wrong length* counts as served: the server sent data and the
    /// range was not honoured, which is as much a reason to stop asking as a refusal is. What must
    /// not count is a piece that never appeared, because that is what a missing file looks like.
    private static func served(_ segments: [DownloadSegment]) -> Int {
        segments.filter { FileManager.default.fileExists(atPath: $0.localPath) }.count
    }
}

/// What one FTP download is about: which remote file, where it lands, the path that names it in an
/// error, and the size the caller already knew.
///
/// Bundled for the reason ``S3DownloadRequest`` is — every step needs the same four and none of them
/// varies between steps, so spelling them out pushes each signature past the parameter-count ceiling
/// the moment a progress hook is added.
struct FTPDownloadRequest {
    let remotePath: String
    let localPath: String
    let source: VFSPath
    /// What the caller's own listing measured, or `nil` when nobody knows. Never a probe.
    let expectedSize: Int64?
}
