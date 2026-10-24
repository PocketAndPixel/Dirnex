import DirnexCore
import Foundation

/// The segmented-download verb: one large file as several guarded ranges at once, in one `curl`
/// (PLAN.md §M32, after Slice 6).
///
/// In its own file for the reason S3's is (`S3CurlTransport+Segmented`), and it decides nothing
/// either. The ranges are `SegmentedDownloadPlan`'s, the invocation is
/// `WebDAVProcessArguments.downloadSegments`', what each section came to is
/// `WebDAVSegmentWriteOut`'s, and joining the pieces is `SegmentAssembly`'s, one layer up in the
/// backend. What lives here is what every verb of this transport owns: the time budget, the
/// credential on stdin, and the process.
extension WebDAVCurlTransport {
    /// Progress is the pieces growing, as for S3's segments: exact, continuous, and capped at the
    /// file's size, so a server answering every range with the whole file cannot run the bar past
    /// it before the backend notices.
    ///
    /// An empty segment list answers `.segments([])` rather than downloading the file: nothing asked
    /// for it. The backend only calls this with a plan.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload {
        guard !segments.isEmpty else { return .segments([]) }
        let session = session(maxTime: transferTimeout)
        let invocation = WebDAVProcessArguments.downloadSegments(
            session: session,
            file: file,
            segments: segments,
            credentials: session.sendsCredentials
                ? WebDAVConfigFile.credentials(username: location.username, password: password)
                : nil
        )
        let result: CurlProcess.Result
        do {
            result = try CurlProcess.run(
                invocation.arguments,
                // Always sent: the sections themselves are in it, credential or not.
                configuration: invocation.configuration,
                // The sections run at once, each under its own `max-time`, and the budget is in the
                // config rather than in `argv`, where `CurlProcess.backstop` would look for it.
                backstop: transferTimeout + 30,
                watching: .destinationFiles(
                    paths: segments.map(\.localPath),
                    totalBytes: segments.reduce(0) { $0 + $1.length }
                ),
                progress: progress,
                isCancelled: isCancelled
            )
        } catch CurlProcess.Failure.launchFailed {
            throw WebDAVResponseError.transport(.other)
        } catch CurlProcess.Failure.timedOut {
            throw WebDAVResponseError.transport(.operationTimedOut)
        }
        return .segments(WebDAVSegmentWriteOut.answers(
            segments: segments,
            standardOutput: SubprocessText.lossyUTF8(result.standardOutput)
        ))
    }
}
