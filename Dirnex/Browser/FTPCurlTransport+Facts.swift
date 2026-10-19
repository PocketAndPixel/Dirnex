import DirnexCore
import Foundation

/// The single listing that carries `MLSD` beside `LIST`, for the exact UTC times a `LIST` stamp
/// cannot hold (`FTPFactsParser`).
///
/// In its own file for the reason the batch and the segmented download are: the transport sits at
/// SwiftLint's `type_body_length`, and the seam to split on is the concept.
///
/// It decides nothing. The invocation is `FTPProcessArguments.listingWithFacts`', what a finished
/// run *meant* is `FTPListingRun`'s, and whether to ask at all is the backend's
/// (`FTPFactsSupport`). What lives here is the scratch files, the process, and the TLS 1.2 retry.
extension FTPCurlTransport {
    /// One folder's `LIST`, with its `MLSD` over the same login when `askingFacts`.
    ///
    /// A failure of the rows is classified exactly as ``listDirectory(_:)``'s is, the exit-18 retry
    /// pinned to TLS 1.2 included: `--fail-early` stops the run at a failed `LIST`, so the exit code
    /// is then `LIST`'s own. A failure of the facts is never thrown — it is an answer
    /// (`FTPListing.Facts`).
    func listing(of remotePath: String, askingFacts: Bool) throws -> FTPListing {
        guard askingFacts else { return FTPListing(rows: try listDirectory(remotePath)) }
        do {
            return try listingWithFacts(remotePath, session: session)
        } catch let error as CurlExit where error.code == 18 && location.security.usesTLS {
            do {
                return try listingWithFacts(remotePath, session: session.with(tls: .forceTLS12))
            } catch let retryError as CurlExit {
                throw FTPTransportError.classify(
                    exitCode: retryError.code,
                    stderr: retryError.standardError
                )
            }
        } catch let error as CurlExit {
            throw FTPTransportError.classify(exitCode: error.code, stderr: error.standardError)
        }
    }

    /// One run of the two sections, answering the listing or throwing the run's ``CurlExit`` when
    /// its rows did not arrive.
    private func listingWithFacts(_ remotePath: String, session: FTPSession) throws -> FTPListing {
        let scratch = try BatchScratch()
        defer { scratch.remove() }
        let rowsPath = scratch.nextOutputPath()
        let factsPath = scratch.nextOutputPath()
        let invocation = FTPProcessArguments.listingWithFacts(
            session: session,
            remotePath: remotePath,
            rowsOutput: rowsPath,
            factsOutput: factsPath,
            credentials: FTPConfigFile.credentials(for: location, password: password)
        )

        let exit: CurlExit
        do {
            let result = try run(
                invocation.arguments,
                configuration: invocation.configuration,
                // Two sequential transfers, each under its own `max-time`, so the run's wall clock
                // is their sum — the runner's default is the larger of them (see `run`).
                backstop: 2 * session.maxTime + 30
            )
            exit = CurlExit(code: 0, standardError: "", standardOutput: result.standardOutput)
        } catch let error as CurlExit {
            exit = error
        }

        switch FTPListingRun.interpret(
            exitCode: exit.code,
            writeOut: exit.standardOutput,
            rows: Self.readListing(at: rowsPath),
            facts: Self.readListing(at: factsPath)
        ) {
        case let .listed(listing):
            return listing
        case .rowsFailed:
            throw exit
        }
    }
}
