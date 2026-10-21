import Foundation

/// One directory as ``FTPBackend`` reads it: `LIST`'s rows, and `MLSD`'s facts about the same rows
/// when the server gave them — both over **one** login, so the exact times cost a second data
/// connection and never a second sign-in.
///
/// The rows are always `LIST`'s and the facts only ever correct their times; ``FTPFactsParser``
/// explains why a server that follows symlinks in `MLSD` makes anything more a data-loss risk.
public struct FTPListing: Sendable, Equatable {
    /// The raw `LIST` output, exactly what ``FTPTransport/listDirectory(_:)`` returns.
    public let rows: String
    /// What came of asking for `MLSD` beside it.
    public let facts: Facts

    /// The `MLSD` half's answer.
    public enum Facts: Sendable, Equatable {
        /// Not asked for: this connection has learned the server has no `MLSD`, or the caller only
        /// asks once it knows the server has one, or the transport cannot send it.
        case notAsked
        /// The raw `MLSD` output.
        case listed(String)
        /// The server answered **500** or **502** — it has no such verb. True of every directory on
        /// it, so ``FTPFactsSupport`` stops asking for the rest of the connection.
        case unsupported
        /// Asked for, and it did not come back for any other reason. It says nothing about the next
        /// directory, so nothing is remembered.
        case unavailable
    }

    public init(rows: String, facts: Facts = .notAsked) {
        self.rows = rows
        self.facts = facts
    }
}

/// Remembers what one connection's server has shown about `MLSD`, so a server without it is asked
/// once rather than beside every listing.
///
/// One instance per **connection**, held by the backend by reference for the reason
/// ``SegmentedDownloadSupport`` is: the backend is a value type copied freely, and a fact about the
/// server must not be copied away with it. It dies with the connection, so a reconnect asks again —
/// the right expiry for something the server's administrator can change.
///
/// **A single listing asks until refused; a batch asks only once a single listing has been
/// answered.** The asymmetry is about failed logins, which are what a server with brute-force
/// protection counts (Synology DSM locks an account after a handful). A single listing carries its
/// two transfers under `--fail-early`, so a refused login stops it after one attempt. A batch cannot
/// — one refused folder must not abandon the rest — and measured 2026-10-19, `curl` signs in again
/// for **every** section after a refused login, so adding a fact section per folder would double
/// what a stale password costs. Asking only once the server has answered keeps that to a session
/// whose login already worked, and a pane always lists its own folder singly before any batch runs.
public final class FTPFactsSupport: @unchecked Sendable {
    private enum State {
        case unknown
        case answered
        case refused
    }

    private let lock = NSLock()
    private var state = State.unknown

    public init() {}

    /// Whether a single listing should ask for `MLSD` beside its `LIST`.
    public var asksWithSingleListing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .refused
    }

    /// Whether a batched listing should — only once this connection has seen `MLSD` work.
    public var asksWithBatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .answered
    }

    /// Learn from one listing's answer. Only the two decisive answers move the state: a listed reply
    /// shows the verb works, and a 500/502 shows it does not exist here. A refusal is final for the
    /// connection, so a later answer cannot undo it.
    public func record(_ facts: FTPListing.Facts) {
        lock.lock()
        defer { lock.unlock() }
        switch facts {
        case .listed where state == .unknown: state = .answered
        case .unsupported: state = .refused
        default: break
        }
    }
}

/// Reads the answer of a single listing run that carried `LIST` and then `MLSD` as two sections of
/// one `curl` (``FTPProcessArguments/listingWithFacts(session:remotePath:rowsOutput:factsOutput:credentials:)``).
///
/// Pure, so the rules that decide what a run *meant* are tested without a server, against outcomes
/// measured 2026-10-19 on a local pyftpdlib with `MLSD` and the same server with it withdrawn:
///
/// | case | exit | stdout | rows | facts |
/// |---|---|---|---|---|
/// | both answered | 0 | `L 0 226` `M 0 226` | file | file |
/// | no `MLSD` | 19 | `L 0 226` `M 19 500` | file | absent |
/// | missing folder | 9 | `L 9 550` | absent | absent |
/// | wrong password | 67 | `L 67 530` | absent | absent |
/// | empty folder | 0 | `L 0 226` `M 0 226` | 0 bytes | 0 bytes |
///
/// The run's exit code is the **last** transfer's, so on its own it cannot say which half failed;
/// the per-section `write-out` line can. Both listings go to files, so stdout carries nothing but
/// those lines — the framing problem that ruled `write-out` out for the batch does not arise.
public enum FTPListingRun {
    /// The `write-out` marker the `LIST` section prints, then its exit code and last reply code.
    static let rowsMarker = "L"
    /// The same for the `MLSD` section.
    static let factsMarker = "M"

    /// What one run produced.
    public enum Outcome: Sendable, Equatable {
        /// The rows arrived, with whatever came of the facts.
        case listed(FTPListing)
        /// `LIST` itself failed, so the run's exit code is `LIST`'s — `--fail-early` stopped the run
        /// there — and the caller classifies it exactly as it classifies a plain listing.
        case rowsFailed
    }

    /// Interpret a finished run: its exit code, its stdout (the `write-out` lines), and the two
    /// output files' contents, `nil` for a file that was never written.
    public static func interpret(
        exitCode: Int32,
        writeOut: String,
        rows: String?,
        facts: String?
    ) -> Outcome {
        let reports = sectionReports(in: writeOut)
        // The rows must have *succeeded*, not merely left a file: a data connection that broke
        // partway leaves a partial one behind, and reading that as the folder would drop the rest of
        // its rows without a word. A run with no `L` line at all is trusted only on a clean exit.
        let rowsSucceeded = reports[rowsMarker].map { $0.exitCode == 0 } ?? (exitCode == 0)
        guard let rows, rowsSucceeded else { return .rowsFailed }

        let answer: FTPListing.Facts
        switch reports[factsMarker] {
        case let report? where report.exitCode == 0:
            answer = facts.map(FTPListing.Facts.listed) ?? .unavailable
        case let report? where report.replyCode == 500 || report.replyCode == 502:
            answer = .unsupported
        default:
            answer = .unavailable
        }
        return .listed(FTPListing(rows: rows, facts: answer))
    }

    /// One section's `write-out` line.
    struct SectionReport: Equatable {
        let exitCode: Int32
        let replyCode: Int
    }

    /// The `marker exit reply` lines, keyed by marker. A line that does not have that shape is
    /// skipped rather than guessed at.
    static func sectionReports(in writeOut: String) -> [String: SectionReport] {
        var reports: [String: SectionReport] = [:]
        for line in writeOut.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let exitCode = Int32(fields[1]), let reply = Int(fields[2])
            else { continue }
            reports[String(fields[0])] = SectionReport(exitCode: exitCode, replyCode: reply)
        }
        return reports
    }
}
