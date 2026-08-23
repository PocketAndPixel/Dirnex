import DirnexCore
import Foundation

/// The segmented-download verb, in its own file for the reason the process plumbing is — the
/// transport sits at SwiftLint's `type_body_length`, and the seam to split on is the concept.
///
/// It decides nothing: the ranges are `SegmentedDownloadPlan`'s, the invocation is
/// `FTPProcessArguments.downloadSegments`', joining the pieces is `SegmentAssembly`'s, and what to
/// do with a failure is `FTPBackend`'s. What lives here is the same three things every other verb
/// here owns — the session's time budget, the credential going in on stdin, and the process.
extension FTPCurlTransport {
    /// Several ranges of one remote file at once, in one `curl` (docs/HISTORY.md ▸ After M19).
    ///
    /// The credential goes into the **configuration** rather than being added by the runner, because
    /// `curl` reads one option set per transfer and each section needs its own copy — and so does
    /// the security half, which is what stops a segmented download quietly losing `--ssl-reqd` or a
    /// certificate pin. It still never touches `argv`, which is the property that matters.
    ///
    /// **No TLS-1.2 retry here, deliberately.** The one documented FTPS symptom (exit 18 on a data
    /// connection that returned nothing) is worth retrying pinned to 1.2 — and a failed segmented
    /// run already falls back to the single-stream download, which *has* that retry. Repeating it
    /// here would spend a second parallel attempt to reach the same place.
    ///
    /// An empty segment list answers `.segments(bytes: 0)` rather than falling back to a whole
    /// download: nothing asked for the file, so nothing should be fetched. It is unreachable from
    /// the backend, which only ever calls this with a plan.
    @discardableResult
    func downloadSegments(
        _ segments: [DownloadSegment],
        of remotePath: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> FTPSegmentedDownload {
        guard !segments.isEmpty else { return .segments(bytes: 0) }
        let invocation = FTPProcessArguments.downloadSegments(
            session: session.with(maxTime: transferTimeout),
            remotePath: remotePath,
            segments: segments,
            credentials: FTPConfigFile.credentials(for: location, password: password)
        )
        do {
            _ = try run(
                invocation.arguments,
                configuration: invocation.configuration,
                watching: .destinationFiles(
                    paths: segments.map(\.localPath),
                    totalBytes: segments.reduce(0) { $0 + $1.length }
                ),
                progress: progress,
                isCancelled: isCancelled
            )
        } catch let error as CurlExit {
            throw FTPTransportError.classify(exitCode: error.code, stderr: error.standardError)
        }
        // The bytes are the pieces on disk. There is nothing per-section to read: a section's reply
        // code is a race and the exit code is the run's, which is why this invocation asks `curl`
        // for no write-out at all (`FTPProcessArguments.downloadSegments`).
        return .segments(bytes: segments.reduce(0) { $0 + Self.fileSize($1.localPath) })
    }

    /// The size of a local file, or 0 when it is not there — a segment the server refused simply
    /// contributes nothing, which is the honest count of what arrived.
    static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }
}
