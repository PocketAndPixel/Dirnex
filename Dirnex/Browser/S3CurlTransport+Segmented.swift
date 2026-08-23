import DirnexCore
import Foundation

/// The segmented-download verb, split into its own file for the reason the multipart verbs are —
/// `S3CurlTransport` sits at SwiftLint's `type_body_length` ceiling, and the seam to split on is the
/// concept rather than the line count.
///
/// It decides nothing: the ranges are `SegmentedDownloadPlan`'s, the invocation is
/// `S3ProcessArguments.downloadSegments`', and joining the pieces is `SegmentAssembly`'s, one
/// layer up in the backend. What lives here is the same three things every other verb here owns —
/// the session's time budget, the credential going in on stdin, and the runner.
extension S3CurlTransport {
    /// Several ranges of one object at once, in one `curl` (docs/HISTORY.md ▸ After M19).
    ///
    /// The credential goes into the **configuration** rather than being added by the runner, because
    /// `curl` reads one option set per transfer and each section needs its own copy. It still never
    /// touches `argv`, which is the property that matters.
    ///
    /// An empty segment list answers `.segments([])` rather than falling back to a whole download:
    /// nothing asked for the object, so nothing should be fetched. It is unreachable from the
    /// backend, which only ever calls this with a plan.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of key: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3SegmentedDownload {
        guard !segments.isEmpty else { return .segments([]) }
        let invocation = S3ProcessArguments.downloadSegments(
            session: session(maxTime: transferTimeout),
            key: key,
            segments: segments,
            credentials: S3ConfigFile.credentials(
                accessKeyID: location.accessKeyID,
                secretAccessKey: secretAccessKey
            )
        )
        return .segments(try runner.performSegments(
            invocation,
            segments: segments,
            totalBytes: segments.reduce(0) { $0 + $1.length },
            progress: progress,
            isCancelled: isCancelled
        ))
    }
}
