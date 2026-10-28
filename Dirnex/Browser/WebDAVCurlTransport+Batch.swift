import DirnexCore
import Foundation

/// The batched-listing verb: a whole level of a tree, or every folder a tree has open, in one `curl`
/// over one connection (PLAN.md §M32 Slice 5).
///
/// In its own file for the reason FTP's is (`FTPCurlTransport+Batch`), and it decides nothing either.
/// Which folders to ask for is `WebDAVBackend`'s, the invocation is
/// `WebDAVProcessArguments.listings`', and what each section came to is `WebDAVBatchWriteOut`'s,
/// read off each section's own line rather than the run's exit code, which is only the last
/// section's. What lives here is what every verb of this transport owns: the scratch files, the
/// credential on stdin, and the process.
extension WebDAVCurlTransport {
    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer] {
        guard !backendPaths.isEmpty else { return [] }
        let scratch = try BatchScratch(label: "webdav")
        defer { scratch.remove() }

        let session = session(maxTime: metadataTimeout)
        let requests = backendPaths.map {
            WebDAVListingRequest(backendPath: $0, outputPath: scratch.nextOutputPath())
        }
        let invocation = WebDAVProcessArguments.listings(
            session: session,
            requests: requests,
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
                // The sections run one after another, each under its own `max-time`, so the run's
                // wall clock is their budgets summed (FTP's reason, `FTPCurlTransport+Batch`).
                backstop: requests.count * metadataTimeout + 30,
                isCancelled: isCancelled
            )
        } catch CurlProcess.Failure.launchFailed {
            throw WebDAVResponseError.transport(.other)
        } catch CurlProcess.Failure.timedOut {
            throw WebDAVResponseError.transport(.operationTimedOut)
        }
        return WebDAVBatchWriteOut.answers(
            sections: requests.count,
            standardOutput: SubprocessText.lossyUTF8(result.standardOutput)
        ) { section in
            // A section that was never sent wrote no file, and its answer is `notSent` whatever
            // this reads.
            (try? Data(contentsOf: URL(fileURLWithPath: requests[section].outputPath))) ?? Data()
        }
    }
}
