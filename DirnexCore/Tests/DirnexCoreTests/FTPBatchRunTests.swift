import Foundation
import Testing

@testable import DirnexCore

/// Reading a batched listing that stops at its first failure (`--fail-early`): where it stopped and
/// why, from what landed and the run's exit. The stderr lines are the ones `curl` 8.7.1 printed
/// against pyftpdlib on 2026-10-23, through the shipped builder.
@Suite("FTP batch run: where it stopped, and why")
struct FTPBatchRunTests {
    private static let loginRefused = "curl: (67) Access denied: 530"
    private static let folderMissing = "curl: (9) Server denied you to change to the given directory"
    private static let folderUnreadable = "curl: (19) RETR response: 550"

    private static let rows = FTPListing(rows: "drwxr-xr-x 2 probe probe 64 Oct 23 19:59 b")

    @Test("a run that exited 0 stopped nothing")
    func cleanRun() {
        let run = FTPBatchRun.reading(
            [Self.rows, Self.rows],
            askingFacts: false,
            exitCode: 0,
            stderr: ""
        )
        #expect(run.stop == nil)
    }

    @Test("a refused login stops at the first folder, as a login")
    func refusedLogin() {
        let run = FTPBatchRun.reading(
            [nil, nil, nil, nil],
            askingFacts: false,
            exitCode: 67,
            stderr: Self.loginRefused
        )
        #expect(run.stop == FTPBatchStop(index: 0, cause: .login))
    }

    @Test("a missing folder stops at itself, after the folders before it landed")
    func missingFolder() {
        let run = FTPBatchRun.reading(
            [Self.rows, Self.rows, nil, nil],
            askingFacts: false,
            exitCode: 9,
            stderr: Self.folderMissing
        )
        #expect(run.stop == FTPBatchStop(index: 2, cause: .folder))
    }

    /// The case the classifier leaves generic: the account may enter the folder and not read it.
    @Test("a folder that can be entered and not read is that folder's refusal")
    func unreadableFolder() {
        let run = FTPBatchRun.reading(
            [Self.rows, nil, nil],
            askingFacts: false,
            exitCode: 19,
            stderr: Self.folderUnreadable
        )
        #expect(run.stop == FTPBatchStop(index: 1, cause: .folder))
        #expect(
            FTPTransportError.classify(exitCode: 19, stderr: Self.folderUnreadable)
                == .failure(Self.folderUnreadable),
            "why 19 needs its own reading"
        )
    }

    @Test("a folder whose rows landed and whose MLSD did not is where it stopped")
    func stopOnFacts() {
        let factless = FTPListing(rows: Self.rows.rows, facts: .unavailable)
        let listed = FTPListing(rows: Self.rows.rows, facts: .listed("type=dir; b"))
        let run = FTPBatchRun.reading(
            [listed, factless, nil],
            askingFacts: true,
            exitCode: 19,
            stderr: "curl: (19) RETR response: 550"
        )
        #expect(run.stop == FTPBatchStop(index: 1, cause: .folder))
        #expect(run.listings[1] == factless, "its rows are kept")
    }

    @Test("a nonzero exit with every answer in hand stopped nothing that was asked")
    func everythingLanded() {
        let run = FTPBatchRun.reading(
            [Self.rows, Self.rows],
            askingFacts: false,
            exitCode: 23,
            stderr: ""
        )
        #expect(run.stop == nil)
    }

    @Test("what each exit stands for")
    func causes() {
        typealias Cause = FTPBatchStop.Cause
        #expect(Cause(exitCode: 67, stderr: Self.loginRefused) == .login)
        #expect(
            Cause(exitCode: 67, stderr: "curl: (67) Access denied: 503") == .login,
            "TLS required"
        )
        #expect(Cause(exitCode: 9, stderr: Self.folderMissing) == .folder)
        #expect(Cause(exitCode: 9, stderr: "curl: (9) Access denied: 530") == .login)
        #expect(Cause(exitCode: 78, stderr: "") == .folder)
        #expect(Cause(exitCode: 19, stderr: Self.folderUnreadable) == .folder)
        #expect(Cause(exitCode: 7, stderr: "curl: (7) Failed to connect") == .connection)
        #expect(Cause(exitCode: 28, stderr: "") == .connection)
        #expect(
            Cause(exitCode: 18, stderr: "") == .connection,
            "the data channel the single listing retries"
        )
        #expect(Cause(exitCode: 90, stderr: "") == .connection)
    }
}

/// The protocol's default for a transport that has not implemented the stopping run: one listing at
/// a time, stopping at the first that throws, so it keeps the guard and loses only the shared login.
@Suite("FTP batch run ▸ the default")
struct FTPBatchRunDefaultTests {
    @Test("lists one folder at a time and stops at the first failure")
    func stopsAtTheFirstFailure() throws {
        let transport = FakeFTPTransport()
        transport.listings = ["/a": "", "/c": ""]
        let run = try SinglesOnly(transport).listingsUntilFirstFailure(
            of: ["/a", "/b", "/c"],
            askingFacts: false,
            isCancelled: { false }
        )
        #expect(run.listings == [FTPListing(rows: ""), nil, nil])
        #expect(run.stop == FTPBatchStop(index: 1, cause: .folder))
        #expect(transport.listedPaths == ["/a"])
    }

    @Test("a refused login is one attempt")
    func refusedLogin() throws {
        let transport = FakeFTPTransport()
        transport.error = .loginDenied
        let run = try SinglesOnly(transport).listingsUntilFirstFailure(
            of: ["/a", "/b"],
            askingFacts: false,
            isCancelled: { false }
        )
        #expect(run.stop == FTPBatchStop(index: 0, cause: .login))
    }
}

/// A transport with nothing of its own but single listings, so the protocol's defaults answer every
/// batched verb. `/b` is missing on this server.
private struct SinglesOnly: FTPTransport {
    let base: FakeFTPTransport

    init(_ base: FakeFTPTransport) { self.base = base }

    func listDirectory(_ remotePath: String) throws -> String {
        if remotePath == "/b", base.error == nil { throw FTPTransportError.notFound }
        return try base.listDirectory(remotePath)
    }

    func makeDirectory(_: String) throws {}
    func createEmptyFile(_: String) throws {}
    func rename(_: String, to _: String) throws {}
    func removeFile(_: String) throws {}
    func removeDirectory(_: String) throws {}
    func fileSize(_: String) throws -> Int64 { 0 }

    func download(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }

    func upload(
        _: String,
        to _: String,
        resume _: Bool,
        progress _: (Int64) -> Void,
        isCancelled _: () -> Bool
    ) throws -> Int64 { 0 }
}
