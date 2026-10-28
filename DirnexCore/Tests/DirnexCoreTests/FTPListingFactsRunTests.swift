import Foundation
import Testing

@testable import DirnexCore

/// The single listing that carries `LIST` and `MLSD` over one login: what the run is asked to do,
/// and what its answers are read as. Every outcome below is one measured on 2026-10-19 against a
/// local pyftpdlib with `MLSD` and the same server with it withdrawn (``FTPListingRun``).
@Suite("FTP listing with facts: the run")
struct FTPListingFactsRunTests {
    // MARK: - Reading the answers

    @Test("both halves answered: the rows and the facts")
    func bothAnswered() {
        let outcome = FTPListingRun.interpret(
            exitCode: 0, writeOut: "L 0 226\nM 0 226\n", rows: "rows", facts: "facts"
        )
        #expect(outcome == .listed(FTPListing(rows: "rows", facts: .listed("facts"))))
    }

    /// The whole of how a server without the verb is recognised: the run ends on `MLSD`'s exit and
    /// reply, and the rows are already on disk.
    @Test("a server without MLSD: the rows, and facts unsupported")
    func serverWithoutMLSD() {
        let outcome = FTPListingRun.interpret(
            exitCode: 19, writeOut: "L 0 226\nM 19 500\n", rows: "rows", facts: nil
        )
        #expect(outcome == .listed(FTPListing(rows: "rows", facts: .unsupported)))
        let notImplemented = FTPListingRun.interpret(
            exitCode: 19, writeOut: "L 0 226\nM 19 502\n", rows: "rows", facts: nil
        )
        #expect(notImplemented == .listed(FTPListing(rows: "rows", facts: .unsupported)))
    }

    /// Any other refusal says nothing about the next folder, so it must not read as "no such verb"
    /// — that would stop asking for the rest of the connection.
    @Test("MLSD failing any other way is unavailable, not unsupported")
    func otherFactsFailure() {
        let outcome = FTPListingRun.interpret(
            exitCode: 19, writeOut: "L 0 226\nM 19 550\n", rows: "rows", facts: nil
        )
        #expect(outcome == .listed(FTPListing(rows: "rows", facts: .unavailable)))
        let silent = FTPListingRun.interpret(
            exitCode: 0, writeOut: "L 0 226\n", rows: "rows", facts: nil
        )
        #expect(silent == .listed(FTPListing(rows: "rows", facts: .unavailable)))
    }

    @Test("an empty folder is two empty answers, not a failure")
    func emptyFolder() {
        let outcome = FTPListingRun.interpret(
            exitCode: 0, writeOut: "L 0 226\nM 0 226\n", rows: "", facts: ""
        )
        #expect(outcome == .listed(FTPListing(rows: "", facts: .listed(""))))
    }

    @Test("LIST failing is the rows failing, whatever else is on disk", arguments: [
        ("L 9 550\n", Int32(9)), ("L 67 530\n", Int32(67)), ("L 18 226\n", Int32(18))
    ])
    func rowsFailed(_ writeOut: String, _ exitCode: Int32) {
        #expect(FTPListingRun.interpret(
            exitCode: exitCode, writeOut: writeOut, rows: nil, facts: nil
        ) == .rowsFailed)
    }

    /// **The quiet direction.** A data connection that broke partway leaves part of a listing on
    /// disk; read as the folder, it would drop every row after the break without a word. Only the
    /// section's own exit code can say the file is not the whole answer.
    @Test("a partial rows file from a failed LIST is not a listing")
    func partialRowsAreNotAListing() {
        let outcome = FTPListingRun.interpret(
            exitCode: 18, writeOut: "L 18 226\n", rows: "-rw-r--r-- 1 a b 1 Jan 1 2020 half",
            facts: nil
        )
        #expect(outcome == .rowsFailed)
    }

    @Test("with no write-out at all, only a clean exit is trusted")
    func noWriteOut() {
        #expect(FTPListingRun.interpret(exitCode: 0, writeOut: "", rows: "rows", facts: nil)
            == .listed(FTPListing(rows: "rows", facts: .unavailable)))
        #expect(FTPListingRun.interpret(exitCode: 18, writeOut: "", rows: "rows", facts: nil)
            == .rowsFailed)
    }

    // MARK: - The latch

    @Test("a single listing asks until refused; a batch only once MLSD has answered")
    func latch() {
        let support = FTPFactsSupport()
        #expect(support.asksWithSingleListing)
        #expect(!support.asksWithBatch)

        support.record(.unavailable)
        support.record(.notAsked)
        #expect(support.asksWithSingleListing)
        #expect(!support.asksWithBatch)

        support.record(.listed(""))
        #expect(support.asksWithSingleListing)
        #expect(support.asksWithBatch)
    }

    @Test("a refusal is final for the connection")
    func refusalIsFinal() {
        let support = FTPFactsSupport()
        support.record(.unsupported)
        support.record(.listed("late"))
        #expect(!support.asksWithSingleListing)
        #expect(!support.asksWithBatch)
    }

    // MARK: - The invocation

    private static func session(security: FTPSecurity = .explicit) -> FTPSession {
        FTPSession(
            location: FTPLocation(host: "ftp.example", username: "u", security: security),
            trust: .pinned(publicKey: "KEY"),
            connectTimeout: 15,
            maxTime: 30
        )
    }

    private static func invocation(security: FTPSecurity = .explicit) -> FTPParallelInvocation {
        FTPProcessArguments.listingWithFacts(
            session: session(security: security),
            remotePath: "/pub",
            rowsOutput: "/tmp/rows",
            factsOutput: "/tmp/facts",
            credentials: "user = \"u:secret\"\n"
        )
    }

    /// `--fail-early` is what keeps a refused login to one attempt; without it `curl` signs in
    /// again for the `MLSD` section, and failed logins are what lock an account.
    @Test("the run fails early and keeps the credential off argv")
    func invocationFlags() {
        let arguments = Self.invocation().arguments
        #expect(arguments == ["-q", "-sS", "--fail-early", "-K", "-"])
        #expect(!arguments.joined().contains("secret"))
    }

    /// `LIST` first, so any failure that is the folder's or the connection's ends the run with
    /// `LIST`'s own exit code.
    @Test("LIST comes first, then MLSD on the same folder")
    func sectionOrder() {
        let sections = Self.invocation().configuration.components(separatedBy: "next\n")
        #expect(sections.count == 2)
        #expect(!sections[0].contains("request"))
        #expect(sections[0].contains("output = \"/tmp/rows\""))
        #expect(sections[0].contains("write-out = \"L %{exitcode} %{response_code}\\n\""))
        #expect(sections[1].contains("request = \"MLSD\""))
        #expect(sections[1].contains("output = \"/tmp/facts\""))
        #expect(sections[1].contains("write-out = \"M %{exitcode} %{response_code}\\n\""))
        for section in sections {
            #expect(section.contains("url = \"ftp://ftp.example:21/pub/\""))
        }
    }

    /// `curl` reads one option set per transfer, so a section missing the TLS lines would run its
    /// `MLSD` in cleartext or against an unpinned certificate.
    @Test("each section carries the credential, the budget, UTF-8 and the TLS settings")
    func everySectionIsComplete() {
        for section in Self.invocation().configuration.components(separatedBy: "next\n") {
            #expect(section.contains("user = \"u:secret\""))
            #expect(section.contains("max-time = 30"))
            #expect(section.contains("quote = \"*OPTS UTF8 ON\""))
            #expect(section.contains("ssl-reqd"))
            #expect(section.contains("pinnedpubkey = \"sha256//KEY\""))
        }
    }

    @Test("a batch request with a facts file gets an MLSD section right after its LIST")
    func batchFactsSections() {
        let invocation = FTPProcessArguments.listDirectories(
            session: Self.session(security: .plain),
            requests: [
                FTPListingRequest(remotePath: "/a", outputPath: "/tmp/1", factsOutputPath: "/tmp/2"),
                FTPListingRequest(remotePath: "/b", outputPath: "/tmp/3")
            ],
            credentials: "user = \"u:secret\"\n"
        )
        let sections = invocation.configuration.components(separatedBy: "next\n")
        #expect(sections.count == 3)
        #expect(sections[0].contains("output = \"/tmp/1\"") && !sections[0].contains("request"))
        #expect(
            sections[1].contains("output = \"/tmp/2\"") && sections[1].contains("request = \"MLSD\"")
        )
        #expect(sections[1].contains("url = \"ftp://ftp.example:21/a/\""))
        #expect(sections[2].contains("output = \"/tmp/3\"") && !sections[2].contains("request"))
        // Still the batch: no early exit, no write-out — one refused folder must not end the run.
        #expect(invocation.arguments == ["-q", "-sS", "-K", "-"])
        #expect(!invocation.configuration.contains("write-out"))
    }
}
