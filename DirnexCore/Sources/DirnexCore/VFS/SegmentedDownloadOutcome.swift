import Foundation

/// What a segmented download turned out to be — the answer the FTP and SFTP transports give.
///
/// Two cases rather than one, because a transport that cannot split a request has not *failed*: it
/// has produced the same file by the older route, and the caller's next step differs entirely —
/// there are pieces to join in one case and nothing to do in the other. Making that a returned
/// distinction is what keeps a forwarding default honest: the one thing a stand-in must never do is
/// look like the thing it stood in for.
///
/// Shared by the two protocols whose answer is a **byte count**, and deliberately not by S3, whose
/// sections each carry an HTTP status worth attributing (``S3SegmentedDownload``). Over FTP and SFTP
/// there is no per-section classification to be had at all — the reply codes are a race in one and a
/// pipeline's exit status masks the failure in the other — so what a run can report is how much
/// arrived, and the pieces themselves are the evidence.
public enum SegmentedDownloadOutcome: Sendable, Equatable {
    /// The pieces are on disk under the paths the segments named, and joining them is the caller's
    /// (``SegmentAssembly``). Carries the bytes this run moved.
    case segments(bytes: Int64)
    /// This transport could not split the request, so the **whole** file was downloaded to the
    /// destination in one stream. There is nothing to assemble and nothing to clean up.
    case whole(bytes: Int64)
}
