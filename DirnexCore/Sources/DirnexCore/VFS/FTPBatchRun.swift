import Foundation

/// What a batched listing that **stops at its first failure** came to: one answer per folder asked,
/// and where the run stopped and why. The tree refresh's batch (``FTPBackend/listDirectories(at:isCancelled:)``).
///
/// It exists because a batch that does not stop costs a failed login per folder when the password
/// is wrong. Measured 2026-10-23 against pyftpdlib through the shipped builder: four sections, four
/// `failed login` lines and four sessions, and the backend's fallback then tried once more. A tree
/// refresh runs on a timer, so a password changed on the server would spend one failed login per open
/// folder every round, and Synology DSM's Account Protection locks the account after a few
/// (docs/NOTES.md ▸ Resolving a host name). With `--fail-early` the same run was one failed login.
///
/// The cost of `--fail-early` is that FTP has no refusal that is not a transfer error. HTTP's 404 is
/// a status, so WebDAV's batch stops only on its first section (`WebDAVProcessArguments.listings`);
/// here a folder that is missing (exit 9) or that may be entered and not read (exit 19,
/// `RETR response: 550`) ends the run as surely as a refused login does. So the run says where it
/// stopped, and the backend sends the folders after a folder's own refusal again.
public struct FTPBatchRun: Sendable, Equatable {
    /// One answer per folder, in order: `nil` for the folder the run stopped on when its rows did
    /// not arrive, and for every folder after it, none of which was sent.
    public let listings: [FTPListing?]
    /// Where the run stopped, or `nil` when every section ran.
    public let stop: FTPBatchStop?

    public init(listings: [FTPListing?], stop: FTPBatchStop?) {
        self.listings = listings
        self.stop = stop
    }
}

/// Where a ``FTPBatchRun`` stopped, and why.
public struct FTPBatchStop: Sendable, Equatable {
    /// The folder whose section stopped the run. Every folder before it was answered, and none after
    /// it was sent. Its own rows are in ``FTPBatchRun/listings`` when the run stopped on its `MLSD`
    /// section rather than its `LIST`.
    public let index: Int
    public let cause: Cause

    public init(index: Int, cause: Cause) {
        self.index = index
        self.cause = cause
    }

    /// Why a run stopped, in the three shapes that decide what to ask next.
    public enum Cause: Sendable, Equatable {
        /// The server refused that folder: missing, a file, or not readable by this account. The
        /// session worked, so the folders after it are worth asking.
        case folder
        /// The server refused the login. Every folder after it would be refused too, and each
        /// refusal would be another failed login.
        case login
        /// No answer, or one that says nothing about the folder: unreachable, timed out, a
        /// certificate, a data channel that returned nothing.
        case connection

        /// The cause of a run's exit, read off its code as ``FTPTransportError/classify(exitCode:stderr:)``
        /// reads one, plus the code that classifier leaves generic.
        ///
        /// **19 is a folder's refusal.** `CURLE_FTP_COULDNT_RETR_FILE`: the server let the account
        /// into the folder and refused its listing, measured as `RETR response: 550` for a folder
        /// whose mode lets it be entered and not read. A server without `MLSD` answers 19 too (500),
        /// which only reaches a batch once this connection has seen the verb answer
        /// (`FTPFactsSupport`), so reading it as that folder's own is the safe side: the rest are
        /// asked again rather than left with stale rows.
        public init(exitCode: Int32, stderr: String) {
            if exitCode == 19 {
                self = .folder
            } else {
                self.init(FTPTransportError.classify(exitCode: exitCode, stderr: stderr))
            }
        }

        /// The cause a single listing's error stands for.
        public init(_ error: FTPTransportError) {
            switch error {
            case .loginDenied, .tlsRequired: self = .login
            case .notFound, .permissionDenied: self = .folder
            case .certificateUntrusted, .certificateChanged, .unreachable, .timedOut,
                 .tlsNotAvailable, .commandNotImplemented, .failure:
                self = .connection
            }
        }
    }
}

public extension FTPBatchRun {
    /// Read a run that carried `--fail-early`: the answers that landed, and the exit code and stderr
    /// of the section that stopped it.
    ///
    /// **The stop is the first answer that is missing.** `--fail-early` ends the run at its first
    /// failed section, so every section before it succeeded and landed its file, an empty folder
    /// included as a 0-byte one (``FTPProcessArguments/listDirectories(session:requests:credentials:stopsAtFirstFailure:)``).
    /// When `askingFacts`, a folder whose rows landed and whose `MLSD` did not is where it stopped.
    /// The run's exit code is that section's, since it was the last to run, and stderr holds its
    /// message alone (measured: 67, 9 and 19 each with one line).
    ///
    /// A nonzero exit with every answer in hand has stopped nothing that was asked, so it is no stop.
    static func reading(
        _ listings: [FTPListing?],
        askingFacts: Bool,
        exitCode: Int32,
        stderr: String
    ) -> FTPBatchRun {
        guard exitCode != 0,
              let index = listings.firstIndex(where: { listing in
                  guard let listing else { return true }
                  return askingFacts && listing.facts == .unavailable
              })
        else { return FTPBatchRun(listings: listings, stop: nil) }
        return FTPBatchRun(
            listings: listings,
            stop: FTPBatchStop(
                index: index,
                cause: FTPBatchStop.Cause(exitCode: exitCode, stderr: stderr)
            )
        )
    }
}
