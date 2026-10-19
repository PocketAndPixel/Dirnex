import Foundation

/// One directory a batched listing asks for, and the file `curl` is to write its `LIST` output to.
///
/// The output file is not an implementation detail that leaked: it is the **only** per-section fact
/// an FTP batch produces, and pairing it with the directory here is what lets the caller say which
/// answer belongs to which request. See
/// ``FTPProcessArguments/listDirectories(session:requests:credentials:)`` for what the two other
/// candidate signals were measured to be worth.
public struct FTPListingRequest: Sendable, Equatable {
    /// The remote directory to list. The trailing slash that makes this a `LIST` is added by the
    /// builder, so callers pass the path exactly as they hold it.
    public let remotePath: String
    /// Where `curl` writes that directory's raw listing. Must be unique within one invocation, and
    /// must not already exist — its absence afterwards is what reports a refusal.
    public let outputPath: String
    /// Where `curl` writes the same directory's `MLSD` reply, or `nil` to ask for `LIST` alone. The
    /// same rules as ``outputPath``: unique, and absent beforehand, since absence is the refusal.
    public let factsOutputPath: String?

    public init(remotePath: String, outputPath: String, factsOutputPath: String? = nil) {
        self.remotePath = remotePath
        self.outputPath = outputPath
        self.factsOutputPath = factsOutputPath
    }
}

public extension FTPProcessArguments {
    /// The most directories one invocation may carry.
    ///
    /// Not a limit `curl` imposes — probed 2026-09-01, **1000 sections is one login, one
    /// invocation, 0.649 s** against a real server, on 234 KB of config, with no sign of a ceiling.
    /// It bounds two things that are ours: the config string and the scratch files held at once,
    /// and the *backstop* the runner derives from the section count, which is a sum here rather
    /// than a maximum (see below). A level wider than this costs one extra login per chunk, which
    /// is the cheapest thing in this whole file to spend.
    static let listingBatchLimit = 200

    /// List several remote directories in **one** `curl`, and therefore over **one** connection —
    /// FTP's answer to ``VFSBackend/subtreeListing(at:isCancelled:)`` (docs/HISTORY.md ▸ After M19).
    ///
    /// FTP has no server-side walk to borrow. SFTP sends the server a `find` over its exec channel
    /// and S3 asks for a delimiter-less listing; FTP has neither, so the tree still costs one `LIST`
    /// per directory and always will. What it *can* stop paying is the **connection** around each
    /// one — a TCP connect, `USER`, `PASS`, `PWD` and `CWD` per directory — and that is nearly all
    /// of the cost. Measured 2026-09-01 against a real server over a 159-directory tree, 527
    /// entries, identical both ways:
    ///
    /// | | invocations | logins | loopback | +50 ms connect |
    /// |---|---|---|---|---|
    /// | one `curl` per directory | 160 | 159 | 1.036 s | 11.264 s |
    /// | one `curl` per level | 4 | 4 | 0.149 s | 0.404 s |
    ///
    /// **28× at a modest 50 ms**, and loopback is the number to distrust: it removes the only cost
    /// this replaces, exactly as the SFTP side's own measurement warns.
    ///
    /// ## What was retired at the probe
    ///
    /// `LIST -R` is the obvious answer and it is not available. `curl -X "LIST -R"` does send it
    /// verbatim (confirmed on the wire), but support in the wild is the minority — ProFTPD and
    /// wu-ftpd yes; vsftpd only under `ls_recurse_enable`, which is off by default and documented
    /// as a denial-of-service risk; pure-ftpd, FileZilla Server, IIS and pyftpdlib no — and **no
    /// server reachable from this Mac honours it**, so the fast path would have shipped unverified.
    /// That is the same trade M22 refused when it retired GNU `find -printf`, and it costs nothing
    /// here: the batch below needs no capability negotiation at all, because it sends the ordinary
    /// `LIST` every server already answers.
    ///
    /// ## Why the run is sequential
    ///
    /// No `-Z`. Parallel is what the segmented download wants and the exact opposite of what this
    /// wants: `curl` opens a connection per parallel transfer, which would re-buy the per-directory
    /// login this exists to avoid. Sequential over one connection is the whole feature — measured,
    /// 5 URLs give one `CONNECT`, one `LOGIN`, five `LIST` and one `DISCONNECT` in the server's own
    /// log.
    ///
    /// ## Why every answer is a file
    ///
    /// Two other signals were measured and neither works:
    ///
    /// - **The exit code is the *last* transfer's, not the run's.** A refused section in the middle
    ///   leaves exit **0**; the same refusal last gives exit **9**. So a batch cannot be classified
    ///   at all — the same finding ``FTPProcessArguments/downloadSegments(session:remotePath:segments:credentials:)``
    ///   already records for FTP, arriving on a listing.
    /// - **`write-out` markers on stdout would have to be framed against the listing's own bytes**,
    ///   and a file name is a stranger's choice: a name carrying a newline and the marker text would
    ///   splice two directories into one.
    ///
    /// What does work is the output file, exactly: a refused section creates **no file**, and an
    /// **empty directory** creates a **0-byte** file. So presence separates "listed, and empty" from
    /// "could not be listed" with nothing to parse — and the bytes that do arrive are byte-identical
    /// to what ``FTPTransport/listDirectory(_:)`` returns, so the batch adds no second dialect and
    /// reuses ``FTPListingParser`` unchanged.
    ///
    /// ## The time budget
    ///
    /// `max-time` is **per transfer**, not per run — probed with five 0.4 s transfers under a 1 s
    /// budget each: 2.056 s total, exit 0, all five landed. So each section keeps the ordinary
    /// metadata budget however many of them there are, and it is only the *process* backstop that
    /// has to be the sum rather than the maximum (`FTPCurlTransport.listDirectories`).
    ///
    /// `credentials` is the already-built config line (``FTPConfigFile/credentials(for:password:)``),
    /// passed in rather than assembled here so this stays a builder that never sees a password.
    ///
    /// ## Exact times
    ///
    /// A request carrying a ``FTPListingRequest/factsOutputPath`` gets a second section right after
    /// its `LIST`: the same folder, asked for `MLSD`, on the same connection. Each answer is still a
    /// file and nothing else, so a folder whose `MLSD` was refused simply has no facts file, and its
    /// rows keep their `LIST` stamps.
    static func listDirectories(
        session: FTPSession,
        requests: [FTPListingRequest],
        credentials: String
    ) -> FTPParallelInvocation {
        let sections = requests.flatMap { request in
            var sections = [listingSection(
                session: session,
                credentials: credentials,
                remotePath: request.remotePath,
                output: request.outputPath
            )]
            if let factsOutput = request.factsOutputPath {
                sections.append(listingSection(
                    session: session,
                    credentials: credentials,
                    remotePath: request.remotePath,
                    output: factsOutput,
                    command: "MLSD"
                ))
            }
            return sections
        }
        return FTPParallelInvocation(
            // `-sS`: no meter, but keep `curl`'s error text — a batch's stderr is the only place a
            // refusal says anything at all, and while nothing keys on it, it is what a diagnosis
            // reads. No `--fail`: a refused `LIST` writes nothing either way (measured), so the flag
            // would be cargo, the same reason the segmented download omits it.
            arguments: ["-sS", "-K", "-"],
            configuration: sections.joined(separator: "next\n")
        )
    }

    /// List one folder with `LIST` and then `MLSD`, over **one** login, each into its own file —
    /// the single listing once a server may have exact times to give (``FTPListingRun``).
    ///
    /// Three choices, each measured 2026-10-19 against a local pyftpdlib:
    ///
    /// - **`LIST` first.** The run's exit code is its last transfer's, and `--fail-early` stops at the
    ///   first failure, so with `LIST` first any failure that is the folder's or the connection's —
    ///   a refused login (67), a folder that is not there (9), the TLS 1.3 empty data channel (18) —
    ///   ends the run with `LIST`'s own code, read exactly as a plain listing's is. Only a run whose
    ///   rows arrived can end on `MLSD`'s.
    /// - **`--fail-early`**, because without it a refused login is tried again for the second
    ///   section, and failed logins are what lock an account on a server that counts them.
    /// - **A `write-out` line per section** (`L 0 226`, then `M 19 500`), which is what tells a
    ///   server without `MLSD` (reply 500) from one whose `MLSD` merely failed. Both listings go to
    ///   files, so stdout carries nothing else.
    static func listingWithFacts(
        session: FTPSession,
        remotePath: String,
        rowsOutput: String,
        factsOutput: String,
        credentials: String
    ) -> FTPParallelInvocation {
        let report = " %{exitcode} %{response_code}\n"
        let sections = [
            listingSection(
                session: session,
                credentials: credentials,
                remotePath: remotePath,
                output: rowsOutput,
                writeOut: FTPListingRun.rowsMarker + report
            ),
            listingSection(
                session: session,
                credentials: credentials,
                remotePath: remotePath,
                output: factsOutput,
                command: "MLSD",
                writeOut: FTPListingRun.factsMarker + report
            )
        ]
        return FTPParallelInvocation(
            arguments: ["-sS", "--fail-early", "-K", "-"],
            configuration: sections.joined(separator: "next\n")
        )
    }

    /// One listing section in config spelling: the credential, the budget, the address family, the
    /// UTF-8 request and the TLS settings — every one of them per section, because `curl` reads one
    /// option set per transfer — then the output file and the folder's URL. `command` replaces
    /// `LIST` (`MLSD`), and `writeOut` is printed when the transfer ends.
    private static func listingSection(
        session: FTPSession,
        credentials: String,
        remotePath: String,
        output: String,
        command: String? = nil,
        writeOut: String? = nil
    ) -> String {
        var lines = [
            credentials.hasSuffix("\n") ? credentials : credentials + "\n",
            "connect-timeout = \(session.connectTimeout)\n",
            "max-time = \(session.maxTime)\n",
            addressFamilyConfiguration(session: session),
            utf8Configuration(),
            securityConfiguration(session: session)
        ]
        if let command { lines.append("request = \(FTPConfigFile.quote(command))\n") }
        if let writeOut { lines.append("write-out = \(FTPConfigFile.quote(writeOut))\n") }
        lines.append("output = \(FTPConfigFile.quote(output))\n")
        lines.append("url = \(FTPConfigFile.quote(listingURL(session, remotePath)))\n")
        return lines.joined()
    }
}
