import Foundation

/// The non-hermetic boundary beneath an `FTPBackend`: it performs remote operations over FTP or
/// FTPS and hands back raw output for the backend to parse. Everything above it — path handling,
/// listing parsing, capability reporting, error mapping — is pure and tested in `DirnexCore`; the
/// transport is where real network I/O lives, so it is injected (PLAN.md §2 "the app is a thin
/// client"), exactly as `SFTPTransport` is.
///
/// The app supplies a `Process`-driven implementation over the system `curl`, which is the third
/// time the project has taken a system CLI over a library (`bsdtar` over libarchive, `sftp` over
/// swift-nio-ssh) and the only option actually available: macOS ships no `ftp`, `tnftp` or `lftp`.
/// Tests supply a fake returning the listings captured in the 2026-07-25 probe, so the whole
/// backend is exercised without a server.
///
/// Every method is synchronous and may block on the network — the backend is always called off the
/// main thread by the operation engine and the panel's background list, never on it.
/// The four write verbs come from ``RemoteWriteTransport``, shared with `SFTPTransport`; over FTP
/// they are `MKD`, `RNFR`+`RNTO` (which must travel as one pair on one connection), `DELE` and
/// `RMD`. FTP has no recursive remove, so `RemoteTransportBackend` empties a directory depth-first
/// before `RMD` — the same walk the SFTP side does.
public protocol FTPTransport: RemoteWriteTransport {
    /// The raw `LIST` output for `remotePath` — one entry per line, in the server's own format
    /// (`FTPListingParser` handles the Unix and DOS dialects). Unlike `sftp`'s `ls`, names come back
    /// **bare**, there are no `.`/`..` rows, and there is no way to list a single file: the backend
    /// stats an item through its *parent's* listing.
    func listDirectory(_ remotePath: String) throws -> String

    /// Download the remote file at `remotePath` to a local path, returning **the bytes transferred
    /// by this call**. With `resume` the transfer continues from the local file's current length
    /// (`curl -C -`) instead of restarting.
    ///
    /// Note the contract differs from `SFTPTransport`'s deliberately: `curl` reports the bytes it
    /// actually moved (`-w '%{size_download}'`), so the *delta* comes back directly and the backend
    /// never has to subtract a pre-existing size to report progress. Verified live — a resumed
    /// download of a 3 MiB file from a 1 MiB partial reported exactly 2 097 152.
    @discardableResult
    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64

    /// Upload the local file at `localPath` to a remote path, returning **the bytes transferred by
    /// this call**. With `resume`, `curl -C -` asks the server for the remote file's current size
    /// and sends only the remainder — so, unlike the SFTP path, the backend needs no size probe of
    /// its own to resume an upload.
    @discardableResult
    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64

    /// The exact size of one remote file (`SIZE`, via `curl -I`), used to decide whether a partial
    /// is resumable. Costs a round trip, so it is a stat-one-item path and never a listing path.
    func fileSize(_ remotePath: String) throws -> Int64

    /// Fetch the server's TLS certificate without trusting it, so the app can show the user what it
    /// is being asked to trust. Only meaningful for an FTPS location; a plain-FTP transport throws.
    ///
    /// Separate from the error vocabulary on purpose: retrieving the certificate is a second `curl`
    /// invocation (`-w '%{certs}'` with verification suppressed), and folding a network round trip
    /// into an error's payload would make every failure path pay for it.
    func fetchCertificate() throws -> FTPCertificate
}

/// A remote FTP operation's failure, in the shapes the backend and the app's trust flow need to
/// distinguish. `classify(exitCode:stderr:)` turns a failed `curl` invocation into one of these.
///
/// **The exit code is the classification, not the stderr text.** This is the one place FTP is
/// genuinely easier than SFTP, and it was measured rather than assumed (2026-07-25): every failure
/// mode that matters comes back as its own documented `curl` exit code, so nothing has to scrape
/// prose. That also makes it locale-proof — `sftp`'s classifier greps English strings and would
/// mis-read a translated OpenSSH, while an exit code says the same thing in every language.
public enum FTPTransportError: Error, Sendable, Equatable {
    /// The remote path does not exist.
    case notFound
    /// The path exists but the account may not read or write it.
    case permissionDenied
    /// Authentication failed — a wrong username or password, or a server that refuses anonymous.
    case loginDenied
    /// The server's certificate did not verify against the system trust store and no pin is stored:
    /// the app must show the user its fingerprint and let them decide (`fetchCertificate`).
    /// Expected on the self-signed certificates NAS boxes ship, which is why it is its own case.
    case certificateUntrusted
    /// A pin **is** stored and the server presented a different key. The FTPS analogue of SSH's
    /// changed-host-key refusal: usually a reissued certificate, but it can be an interception — so
    /// it drives a warning and an explicit re-trust, never a silent retry.
    case certificateChanged
    /// The host could not be resolved or connected to.
    case unreachable
    /// The operation exceeded its time budget.
    case timedOut
    /// The connection asked for a TLS level the server does not offer — explicit FTPS against a
    /// port that speaks only plain FTP. `curl`'s `CURLE_USE_SSL_FAILED` (exit 64). Distinct from
    /// ``certificateUntrusted``: there is no certificate to weigh, because the upgrade never
    /// happened, so the fix is to change the security mode or the port, not to trust anything.
    case tlsNotAvailable
    /// The server requires TLS before it will accept a login, and the connection was plain FTP —
    /// so the login is refused (exit 67) with reply **503** ("bad sequence of commands") before
    /// the password is ever weighed. Distinct from ``loginDenied``: the credentials may be
    /// perfect; the fix is to switch to FTPS, not to re-check the user name and password.
    case tlsRequired
    /// Anything else, carrying `curl`'s own text verbatim.
    ///
    /// **Empty when there was nothing to say**, deliberately — this is the tool's words, not ours,
    /// and the core has no business authoring a sentence it cannot translate (PLAN.md §M12
    /// Slice 11). The app supplies a localized stand-in for the empty case.
    case failure(String)

    /// Classify a failed `curl` invocation. Codes are `curl`'s documented exit values, each one
    /// observed in the probe against a live server; the reply-code scan only disambiguates the two
    /// codes that genuinely need it.
    public static func classify(exitCode: Int32, stderr: String) -> FTPTransportError {
        switch exitCode {
        case 6, 7: return .unreachable
        case 28: return .timedOut
        case 60, 35, 58, 59, 77, 83: return .certificateUntrusted
        case 90, 91: return .certificateChanged
        // 64 is `CURLE_USE_SSL_FAILED` — a required TLS upgrade the server would not do, raised
        // when explicit FTPS meets a plain-only port (observed against port 2121, 2026-07-25).
        case 64: return .tlsNotAvailable
        // 67 is a login denial. A 503 reply on it is not a bad credential but a server that
        // demands AUTH TLS first, refusing a plain-FTP login before the password matters (observed
        // against a TLS-only port). Every other 67 — 530 and the rest — is a genuine login failure.
        // `ftpReplyCode` narrows to 4xx/5xx and takes the last match, so the server's address in
        // the message can't be misread as the reply.
        case 67: return ftpReplyCode(in: stderr) == 503 ? .tlsRequired : .loginDenied
        case 78: return .notFound
        // 9 is `CURLE_FTP_ACCESS_DENIED` — "couldn't cd into the directory", raised both for a
        // directory that isn't there and for one the account may not enter. 21 is a failed `-Q`
        // command, which carries the server's reply code in its message. Both are resolved the same
        // way, by the reply code, and both fall back to `notFound` because that is the reading a
        // browse recovers from.
        case 9, 21: return replyCodeMeaning(in: stderr)
        default:
            return .failure(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Read the three-digit FTP reply code out of `curl`'s message and map it.
    ///
    /// FTP's own vocabulary is the limit here, not the parsing: **550 means both "no such file" and
    /// "permission denied"** — the RFC 959 text is "Requested action not taken: file unavailable",
    /// and servers use it for both. It is read as ``notFound`` because that is what a browse can
    /// recover from, and because claiming "permission denied" for a path that simply isn't there
    /// sends the user to check the wrong thing.
    private static func replyCodeMeaning(in stderr: String) -> FTPTransportError {
        switch ftpReplyCode(in: stderr) {
        case 530: return .loginDenied
        case 532, 552: return .permissionDenied
        // 553 is "file name not allowed" — a write the server rejected on the name itself.
        case 553: return .permissionDenied
        default: return .notFound
        }
    }

    /// The FTP reply code in `curl`'s message, or `nil`. `curl` phrases these as `QUOT command
    /// failed with 550`, so the code is the trailing number, but every token is scanned in case the
    /// wording drifts.
    ///
    /// Only **4xx and 5xx** count, and the *last* match wins. Both narrowings are needed because
    /// these messages routinely contain other three-digit runs: `192.168.1.50` yields `192`, and a
    /// naive first-match scan would classify a failure by an octet of the server's address. Since
    /// this is only ever consulted on a failure, restricting to the negative-reply range loses
    /// nothing.
    static func ftpReplyCode(in stderr: String) -> Int? {
        var found: Int?
        for token in stderr.split(whereSeparator: { !$0.isNumber }) {
            guard token.count == 3, let value = Int(token), (400...599).contains(value) else {
                continue
            }
            found = value
        }
        return found
    }
}
