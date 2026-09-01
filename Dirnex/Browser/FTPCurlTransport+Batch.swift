import DirnexCore
import Foundation

/// The batched-listing verb — a whole level of a tree over one connection, which is what makes
/// `FTPBackend.subtreeListing` worth having (docs/HISTORY.md ▸ After M19).
///
/// In its own file for the reason the segmented download and the process plumbing are: the
/// transport sits at SwiftLint's `type_body_length`, and the seam to split on is the concept.
///
/// It decides nothing. Which directories to ask for is `FTPBackend`'s, the invocation is
/// `FTPProcessArguments.listDirectories`', and the listings are `FTPListingParser`'s — byte for
/// byte the same parser the single listing feeds, because each section's output is byte for byte
/// what a single `LIST` returns. What lives here is the three things every verb here owns: the
/// scratch files, the credential going in on stdin, and the process.
extension FTPCurlTransport {
    /// List several directories in one `curl`, answering `nil` for any that could not be listed.
    ///
    /// ## Why the exit code is never consulted
    ///
    /// Probed 2026-09-01 against a real server: a refused section **in the middle** of a run leaves
    /// exit **0**, and the identical refusal **last** gives exit **9** — the code belongs to the last
    /// transfer, not to the run. So reading it would discard a whole good level whenever its final
    /// directory happened to be unreadable, and the subtree would come back silently short while
    /// still claiming to be complete. The per-section fact is the **file**: `curl` writes none at all
    /// for a refused section, and a 0-byte one for a directory that is genuinely empty, so presence
    /// separates the two exactly. A nonzero exit is therefore read and thrown away here.
    ///
    /// A run in which *nothing* landed is the shape of a real failure — a connection refused, a
    /// login denied, TLS declined — and it needs no special case: every answer is `nil`, which the
    /// backend already reads as "no shortcut" at the root and "skip it" below.
    ///
    /// ## Why there is no TLS-1.2 retry
    ///
    /// The same reason `downloadSegments` has none. The one documented FTPS symptom (exit 18, a data
    /// connection that returned nothing) is worth retrying pinned to 1.2 — and a batch that fails
    /// falls back to the **walk**, whose `listDirectory` carries that retry already. Repeating it
    /// here would spend a second whole-level attempt to reach the same place.
    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        guard !remotePaths.isEmpty else { return [] }
        let scratch = try BatchScratch()
        defer { scratch.remove() }

        var answers: [String?] = []
        answers.reserveCapacity(remotePaths.count)
        // Chunked so the config string, the scratch files held at once, and the process backstop all
        // stay bounded. Each chunk is its own connection, which is the only thing a wider level
        // would have saved — the cheapest thing here to spend.
        for chunk in remotePaths.chunked(by: FTPProcessArguments.listingBatchLimit) {
            guard !isCancelled() else { throw CancellationError() }
            answers += try listChunk(chunk, into: scratch, isCancelled: isCancelled)
        }
        return answers
    }

    private func listChunk(
        _ remotePaths: [String],
        into scratch: BatchScratch,
        isCancelled: () -> Bool
    ) throws -> [String?] {
        let requests = remotePaths.map {
            FTPListingRequest(remotePath: $0, outputPath: scratch.nextOutputPath())
        }
        let invocation = FTPProcessArguments.listDirectories(
            session: session,
            requests: requests,
            credentials: FTPConfigFile.credentials(for: location, password: password)
        )
        do {
            _ = try run(
                invocation.arguments,
                configuration: invocation.configuration,
                // The sections run one after another, so the run's own wall clock is their budgets
                // **summed** rather than the largest of them — the runner's default is the maximum,
                // which is right for a parallel batch and would kill a healthy sequential one.
                backstop: requests.count * metadataTimeout + 30,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is CurlExit {
            // Deliberately swallowed — see the note above. The files are the answers.
        }
        return requests.map { request in
            // `contentsOfFile` rather than an existence check followed by a read: a file that is
            // there and unreadable is as much "no answer" as one that was never written, and the two
            // must not be told apart here.
            try? String(contentsOfFile: request.outputPath, encoding: .utf8)
        }
    }
}

/// A directory the batch writes its per-section listings into, and the counter that keeps their
/// names unique across every chunk of one call.
///
/// One directory per call rather than one shared with the process: two subtree walks can be in
/// flight at once (a search in one pane and a folder size in the other), and a name reused across
/// them would hand one walk the other's listing.
private final class BatchScratch {
    private let directory: String
    private var issued = 0

    init() throws {
        directory = NSTemporaryDirectory() + "dirnex-ftp-list-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
    }

    /// A path `curl` is to create. It must **not** already exist: the whole per-section signal is
    /// that a refused listing leaves no file, so a name that could be left over from an earlier
    /// chunk would read as an answer.
    func nextOutputPath() -> String {
        issued += 1
        return directory + "/\(issued)"
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private extension Array {
    /// Fixed-size slices, in order. `stride` rather than a running buffer so the last chunk is
    /// simply whatever is left.
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map { Array(
            self[$0..<Swift.min($0 + size, count)]
        ) }
    }
}
