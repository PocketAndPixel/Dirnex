import Foundation

/// Downloading one remote file over several SSH exec channels at once
/// (docs/HISTORY.md ▸ After M19).
///
/// The third of three, and the one whose *route* had to be different: the system `curl` speaks no
/// `sftp`, and `sftp(1)` has no range verb, so there is no multi-transfer driver to lean on and each
/// segment is its own `ssh` running ``SSHSegmentCommand``. What that costs — N concurrent children
/// instead of one — is real and is paid in the transport; what it buys is the same as the other two.
///
/// Two things follow from the route rather than from the design, and both were measured against a
/// real `sshd` on 2026-08-24:
///
/// - **An account confined to the `sftp` subsystem has no exec channel**, and refuses with the
///   sentence "This service allows sftp connections only." on *stdout* — where a piece's bytes go.
///   So a perfectly healthy server can refuse this, the refusal arrives as 43 bytes of data rather
///   than as an error, and only the piece's **length** tells them apart.
/// - **A pipeline hides its first stage's failure**: a missing remote path gives `ssh` exit 0 and a
///   zero-byte piece, because the status belongs to `head`. `set -o pipefail` is not POSIX and the
///   shell is the user's own, so there is nothing to set.
///
/// Which is why this never diagnoses: any failure hands back to the plain `sftp` download, whose
/// error is the one worth reporting, and the connection remembers so the next file does not pay for
/// the same refusal (``SegmentedDownloadSupport``).
extension SFTPBackend {
    /// Download `remotePath` as `plan`'s ranges, at once, and join them into `localPath`.
    ///
    /// Returns the bytes moved, or **`nil`** when the caller must fetch the file in one stream
    /// instead — which is every failure except a cancellation. A cancellation is the user's decision
    /// and is re-thrown: retrying what somebody just stopped is the one fallback never wanted.
    func downloadInSegments(
        _ request: SFTPDownloadRequest,
        plan: SegmentedDownloadPlan,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sftp-segments-\(UUID().uuidString)", isDirectory: true)
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
    /// A piece that is *present but the wrong length* counts as served, and over this route that is
    /// the ordinary shape of a refusal: an `sftp`-only account answers with 43 bytes of prose, and a
    /// pipeline whose `tail` failed answers with nothing at all. Both are "the server responded and
    /// this cannot work", which is as much reason to stop asking as an outright error.
    private static func served(_ segments: [DownloadSegment]) -> Int {
        segments.filter { FileManager.default.fileExists(atPath: $0.localPath) }.count
    }
}

/// What one SFTP download is about: which remote file, where it lands, the path that names it in an
/// error, and the size the caller already knew.
///
/// Bundled for the reason ``FTPDownloadRequest`` is — every step needs the same four and none of
/// them varies between steps, so spelling them out pushes each signature past the parameter-count
/// ceiling the moment a progress hook is added.
struct SFTPDownloadRequest {
    let remotePath: String
    let localPath: String
    let source: VFSPath
    /// What the caller's own listing measured, or `nil` when nobody knows. Never a probe.
    let expectedSize: Int64?
}
