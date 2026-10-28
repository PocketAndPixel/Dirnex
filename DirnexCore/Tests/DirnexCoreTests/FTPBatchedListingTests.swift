import Foundation
import Testing

@testable import DirnexCore

/// FTP's ``VFSBackend/listDirectories(at:isCancelled:)``: the folders a tree refresh re-lists, over
/// one login instead of one each.
///
/// Like the subtree shortcut's suite, the claims split in two. What it *answers* must be what
/// listing each folder would have answered, and `answersWhatEachListingWould` compares against
/// exactly that. What it *costs* is the point and is invisible in the answers, so the transport
/// records every batch and every single listing — a version that looped would pass every answer
/// test here and fail `listsSeveralFoldersOverOneConnection`.
@Suite("FTP batched listing")
struct FTPBatchedListingTests {
    private let location = FTPLocation(host: "ftp.example.com", username: "sa")

    /// The reported tree: the root and the two folders open under it.
    private let folders = ["/", "/SYNERGIE", "/SYNERGIE/AGENCE"]

    private func makeBackend() -> (FTPBackend, ScriptedFTPTransport) {
        let transport = ScriptedFTPTransport()
        transport.listings["/"] = "drwxr-xr-x 2 sa users 4096 Jun 14  2024 SYNERGIE"
        transport.listings["/SYNERGIE"] = [
            "drwxr-xr-x 2 sa users 4096 Oct 19 14:36 AGENCE",
            "drwxr-xr-x 2 sa users 4096 Oct 19 03:15 HISTO"
        ].joined(separator: "\n")
        transport.listings["/SYNERGIE/AGENCE"] = [
            "-rw-r--r-- 1 sa users  876544 Oct 19 01:00 Agences_e-Testing.xml",
            "-rw-r--r-- 1 sa users 2936012 Oct 19 14:36 Agences_SYNERGIE_ATS.xml"
        ].joined(separator: "\n")
        return (FTPBackend(location: location, transport: transport), transport)
    }

    private func paths(_ remotePaths: [String]) -> [VFSPath] {
        remotePaths.map { VFSPath(backend: .ftp(location), path: $0) }
    }

    @Test("lists several folders over one connection")
    func listsSeveralFoldersOverOneConnection() throws {
        let (backend, transport) = makeBackend()
        _ = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(transport.batches == [folders])
        #expect(transport.singleAttempts.isEmpty)
        #expect(transport.signIns == 1)
    }

    @Test("answers what listing each folder would have answered")
    func answersWhatEachListingWould() throws {
        let (backend, _) = makeBackend()
        let (reference, _) = makeBackend()
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        let expected = try paths(folders).map { try reference.listDirectory(at: $0) }
        #expect(answers == expected)
        // Not vacuous: the file the report was about is among them, under its own folder.
        #expect(
            answers[2]?.map(\.path.path).contains("/SYNERGIE/AGENCE/Agences_SYNERGIE_ATS.xml") == true
        )
    }

    /// A tree with nothing open, and list mode: a batch of one gains nothing, and the single `LIST`
    /// is the route that carries the TLS-1.2 retry.
    @Test("one folder takes the single listing")
    func oneFolderTakesTheSingleListing() throws {
        let (backend, transport) = makeBackend()
        let answers = try backend.listDirectories(at: paths(["/SYNERGIE"]), isCancelled: { false })
        #expect(answers.first??.count == 2)
        #expect(transport.batches.isEmpty)
        #expect(transport.singleAttempts == ["/SYNERGIE"])
    }

    /// A folder the server will not list — a permission gap, or one deleted since it was opened —
    /// ends a run that stops at its first failure, as `--fail-early` does on FTP (exit 9, or 19 for
    /// one that can be entered and not read). It is an answer about that folder from a session that
    /// worked, so the folders after it go out in one more run rather than one each.
    @Test("a refused folder answers nil and the folders after it go out in one more run")
    func refusedFolderAnswersNil() throws {
        let (backend, transport) = makeBackend()
        transport.refused = ["/SYNERGIE"]
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[0]?.count == 1)
        #expect(answers[1] == nil)
        #expect(answers[2]?.count == 2)
        #expect(transport.batches == [folders, ["/SYNERGIE/AGENCE"]])
        #expect(transport.singleAttempts.isEmpty)
    }

    @Test("a refused first folder sends all the rest again")
    func refusedFirstFolderSendsTheRest() throws {
        let (backend, transport) = makeBackend()
        transport.refused = ["/"]
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[0] == nil)
        #expect(answers[1]?.count == 2)
        #expect(answers[2]?.count == 2)
        #expect(transport.batches == [folders, Array(folders.dropFirst())])
    }

    /// The distinction the tree keeps rows by: `nil` keeps a folder's last good rows, an empty list
    /// empties it. Conflating them would either blank a folder on a refusal or freeze one that
    /// really was emptied.
    @Test("an emptied folder answers an empty list, not nil")
    func emptiedFolderAnswersEmpty() throws {
        let (backend, transport) = makeBackend()
        transport.listings["/SYNERGIE/AGENCE"] = ""
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[2] == [])
    }

    /// The finding this guards (measured 2026-10-23 against pyftpdlib): a batch that does not stop
    /// signs in again for every section after a refused login, four sections being four failed
    /// logins, and the fallback then asked once more. A refresh runs on a timer, so a password
    /// changed on the server spent that every round, against an Account Protection that locks the
    /// account after a few.
    @Test("a refused login is one failed login a round, whatever the number of folders")
    func refusedLoginIsOneFailedLogin() throws {
        let (backend, transport) = makeBackend()
        transport.loginRefused = true
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers == [nil, nil, nil])
        #expect(transport.signIns == 1)
        #expect(transport.singleAttempts.isEmpty)
    }

    /// A run that got no answer — the data channel needing the TLS-1.2 retry only the single
    /// listing has, say — is the batch's failure as much as the server's. The folders are still
    /// listed, one at a time.
    @Test("a run with no answer falls back to one listing per folder")
    func noAnswerFallsBackToSingleListings() throws {
        let (backend, transport) = makeBackend()
        transport.noAnswerAt = 0
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers.allSatisfy { $0 != nil })
        #expect(transport.singleAttempts == folders)
    }

    @Test("a run that loses its answer part-way keeps what landed and lists the rest singly")
    func noAnswerPartWay() throws {
        let (backend, transport) = makeBackend()
        transport.noAnswerAt = 1
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers.allSatisfy { $0 != nil })
        #expect(transport.singleAttempts == Array(folders.dropFirst()))
    }

    @Test("a run that throws, or answers the wrong number, falls back the same way")
    func brokenRunFallsBackToSingleListings() throws {
        for breakRun in [
            { (transport: ScriptedFTPTransport) in transport.batchThrows = true },
            { (transport: ScriptedFTPTransport) in transport.batchMiscounts = true }
        ] {
            let (backend, transport) = makeBackend()
            breakRun(transport)
            let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
            #expect(answers.allSatisfy { $0 != nil })
            #expect(transport.singleAttempts == folders)
        }
    }

    /// The fallback's own guard: a server refusing us altogether, met there rather than by the run,
    /// is asked once more and not once per folder.
    @Test("a server refusing the login on the fallback is asked once, not once per folder")
    func refusingServerIsAskedOnce() throws {
        let (backend, transport) = makeBackend()
        transport.batchThrows = true
        transport.loginRefused = true
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers == [nil, nil, nil])
        #expect(transport.singleAttempts == ["/"])
    }

    /// A run that stopped on a folder's `MLSD`, after its `LIST` landed: the rows are that folder's
    /// answer, and the folders after it are sent again.
    @Test("a stop after a folder's rows landed keeps them, and sends the rest again")
    func stopAfterRowsKeepsThem() throws {
        let (backend, transport) = makeBackend()
        transport.stopsAfterRowsOf = "/SYNERGIE"
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[1]?.count == 2)
        #expect(answers[2]?.count == 2)
        #expect(transport.batches == [folders, ["/SYNERGIE/AGENCE"]])
    }

    @Test("a folder on another connection is refused before anything reaches the wire")
    func foreignFolderIsRefused() {
        let (backend, transport) = makeBackend()
        let elsewhere = VFSPath(
            backend: .ftp(FTPLocation(host: "other.example.com", username: "sa")), path: "/"
        )
        #expect(throws: VFSError.self) {
            _ = try backend.listDirectories(at: paths(["/"]) + [elsewhere], isCancelled: { false })
        }
        #expect(transport.batches.isEmpty)
        #expect(transport.singleAttempts.isEmpty)
    }

    @Test("cancellation travels")
    func cancellationTravels() {
        let (backend, _) = makeBackend()
        #expect(throws: CancellationError.self) {
            _ = try backend.listDirectories(at: paths(folders), isCancelled: { true })
        }
    }
}

/// The protocol's forwarding default, which every backend but FTP takes.
@Suite("Batched listing ▸ the forwarding default")
struct ForwardedBatchedListingTests {
    @Test("lists each folder, and answers nil for one that cannot be listed")
    func listsEachFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-batch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/a.txt"))
        let backend = LocalBackend()
        let paths: [VFSPath] = [
            .local(root.path),
            .local(root.path + "/sub"),
            .local(root.path + "/gone")
        ]

        let answers = try backend.listDirectories(at: paths, isCancelled: { false })
        #expect(answers.count == 3)
        #expect(answers[0]?.map(\.name) == ["sub"])
        #expect(answers[1]?.map(\.name) == ["a.txt"])
        #expect(answers[2] == nil)
    }

    @Test("cancellation travels")
    func cancellationTravels() {
        #expect(throws: CancellationError.self) {
            _ = try LocalBackend().listDirectories(at: [.local("/tmp")], isCancelled: { true })
        }
    }
}

// MARK: - Double

/// A transport whose runs and single listings can fail independently — which no shared flag on
/// `FakeFTPTransport` can express — and which counts **sign-ins** the way the server's log counted
/// them: a run that does not stop signs in again for every section after a refused login, a run that
/// stops at its first failure signs in once, and a single listing once.
private final class ScriptedFTPTransport: FTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    /// Folders the server refuses, in a run and singly alike.
    var refused: Set<String> = []
    /// The server refuses the login.
    var loginRefused = false
    /// The section of a stopping run that gets no answer, while single listings work.
    var noAnswerAt: Int?
    /// The folder whose rows land before the run stops on its facts.
    var stopsAfterRowsOf: String?
    var batchThrows = false
    var batchMiscounts = false
    private(set) var batches: [[String]] = []
    private(set) var singleAttempts: [String] = []
    private(set) var signIns = 0

    func listDirectory(_ remotePath: String) throws -> String {
        singleAttempts.append(remotePath)
        signIns += 1
        if loginRefused { throw FTPTransportError.loginDenied }
        if refused.contains(remotePath) { throw FTPTransportError.permissionDenied }
        return listings[remotePath] ?? ""
    }

    /// The run that does not stop, which the subtree walk keeps.
    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        guard !isCancelled() else { throw CancellationError() }
        batches.append(remotePaths)
        if batchThrows { throw FTPTransportError.failure("batch") }
        signIns += loginRefused ? remotePaths.count : 1
        if loginRefused { return remotePaths.map { _ in nil } }
        return remotePaths.map { refused.contains($0) ? nil : listings[$0] ?? "" }
    }

    func listingsUntilFirstFailure(
        of remotePaths: [String],
        askingFacts _: Bool,
        isCancelled: () -> Bool
    ) throws -> FTPBatchRun {
        guard !isCancelled() else { throw CancellationError() }
        batches.append(remotePaths)
        if batchThrows { throw FTPTransportError.failure("batch") }
        signIns += 1
        if batchMiscounts { return FTPBatchRun(listings: [], stop: nil) }
        var answered: [FTPListing?] = []
        func stopped(_ cause: FTPBatchStop.Cause) -> FTPBatchRun {
            let unsent = Array(
                repeating: FTPListing?.none,
                count: remotePaths.count - answered.count
            )
            return FTPBatchRun(
                listings: answered + unsent,
                stop: FTPBatchStop(index: answered.count, cause: cause)
            )
        }
        if loginRefused { return stopped(.login) }
        for (index, path) in remotePaths.enumerated() {
            if index == noAnswerAt { return stopped(.connection) }
            if refused.contains(path) { return stopped(.folder) }
            if path == stopsAfterRowsOf {
                let run = stopped(.folder)
                var withRows = run.listings
                withRows[index] = FTPListing(rows: listings[path] ?? "", facts: .unavailable)
                return FTPBatchRun(listings: withRows, stop: run.stop)
            }
            answered.append(FTPListing(rows: listings[path] ?? ""))
        }
        return FTPBatchRun(listings: answered, stop: nil)
    }

    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func fileSize(_ remotePath: String) throws -> Int64 { 0 }

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 { 0 }

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 { 0 }
}
