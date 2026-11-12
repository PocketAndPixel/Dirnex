import DirnexCore
import Foundation

/// The batched-listing verb: every folder a tree refresh re-lists, in one `sftp` session rather
/// than one session each. And the space-left question, the other verb whose answer is read from a
/// transcript.
///
/// In its own file for the reason the segmented transfers are: the transport sits near SwiftLint's
/// `type_body_length`, and the seam to split on is the concept.
///
/// It decides nothing. The batch and the reading of what came back are `SFTPBatchListing`'s, and
/// each folder's rows are `SFTPListingParser`'s, byte for byte as for a single listing. What lives
/// here is the run.
extension SFTPProcessTransport {
    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        guard !remotePaths.isEmpty else { return [] }
        // A password session's deadline bounds the whole run, so a batch is given what the
        // listings it replaces were given between them; a healthy server answers in a fraction.
        var session = self
        session.passwordTimeout = passwordTimeout * remotePaths.count
        let transcript = try session.run(
            transcript: SFTPBatchListing.script(for: remotePaths), isCancelled: isCancelled
        )
        return SFTPBatchListing.answers(in: transcript, for: remotePaths)
    }

    /// One of the space-left sessions, run as the batched listing is and for its reason: what tells
    /// a server without the extension from a failed session is one sentence on standard error, while
    /// the tables and the listing are on standard output, so the core reads them in one transcript,
    /// framed by the echoes (``SFTPDiskFree``).
    func diskFree(_ batch: String) throws -> String {
        try run(transcript: batch, isCancelled: { false })
    }
}
