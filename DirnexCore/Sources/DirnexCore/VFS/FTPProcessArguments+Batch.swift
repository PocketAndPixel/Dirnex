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

    public init(remotePath: String, outputPath: String) {
        self.remotePath = remotePath
        self.outputPath = outputPath
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
    static func listDirectories(
        session: FTPSession,
        requests: [FTPListingRequest],
        credentials: String
    ) -> FTPParallelInvocation {
        let security = securityConfiguration(session: session)
        let sections = requests.map { request in
            [
                credentials.hasSuffix("\n") ? credentials : credentials + "\n",
                "connect-timeout = \(session.connectTimeout)\n",
                "max-time = \(session.maxTime)\n",
                addressFamilyConfiguration(session: session),
                security,
                "output = \(FTPConfigFile.quote(request.outputPath))\n",
                "url = \(FTPConfigFile.quote(listingURL(session, request.remotePath)))\n"
            ].joined()
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
}
