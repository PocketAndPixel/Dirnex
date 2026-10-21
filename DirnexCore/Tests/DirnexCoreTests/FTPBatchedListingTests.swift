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
    /// is an answer about that folder from a session that worked, so it costs no further login and
    /// does not cost the others their rows.
    @Test("a refused folder answers nil and the rest still land, without another login")
    func refusedFolderAnswersNil() throws {
        let (backend, transport) = makeBackend()
        transport.refused = ["/SYNERGIE"]
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[0]?.count == 1)
        #expect(answers[1] == nil)
        #expect(answers[2]?.count == 2)
        #expect(transport.singleAttempts.isEmpty)
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

    /// The batch itself failing — `curl` with several URLs on a server that dislikes it, or the data
    /// channel needing the retry only the single listing has. The folders are still listed, one
    /// at a time.
    @Test("a batch that lands nothing falls back to one listing per folder")
    func emptyBatchFallsBackToSingleListings() throws {
        let (backend, transport) = makeBackend()
        transport.batchLandsNothing = true
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers.allSatisfy { $0 != nil })
        #expect(transport.singleAttempts == folders)
    }

    @Test("a batch that throws falls back the same way")
    func throwingBatchFallsBackToSingleListings() throws {
        let (backend, transport) = makeBackend()
        transport.batchThrows = true
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers.allSatisfy { $0 != nil })
        #expect(transport.singleAttempts == folders)
    }

    /// The guard on the fallback, and the half that matters on a server counting failed logins: a
    /// server refusing us *altogether* empties the batch too, and must then be asked once more —
    /// not once per folder, every round.
    @Test("a server refusing the login is asked once more, not once per folder")
    func refusingServerIsAskedOnce() throws {
        let (backend, transport) = makeBackend()
        transport.batchLandsNothing = true
        transport.refused = Set(folders)
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers == [nil, nil, nil])
        #expect(transport.singleAttempts == ["/"])
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

/// A transport whose batch and single listing can fail independently — which no shared flag on
/// `FakeFTPTransport` can express — and which records **every attempt**, refused ones included, so
/// a test can count the logins a failing server was asked for.
private final class ScriptedFTPTransport: FTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    /// Folders the server refuses, in a batch and singly alike.
    var refused: Set<String> = []
    /// A batch run in which nothing landed — the shape `FTPCurlTransport` gives a failed run.
    var batchLandsNothing = false
    var batchThrows = false
    private(set) var batches: [[String]] = []
    private(set) var singleAttempts: [String] = []

    func listDirectory(_ remotePath: String) throws -> String {
        singleAttempts.append(remotePath)
        if refused.contains(remotePath) { throw FTPTransportError.permissionDenied }
        return listings[remotePath] ?? ""
    }

    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        guard !isCancelled() else { throw CancellationError() }
        batches.append(remotePaths)
        if batchThrows { throw FTPTransportError.failure("batch") }
        if batchLandsNothing { return remotePaths.map { _ in nil } }
        return remotePaths.map { refused.contains($0) ? nil : listings[$0] ?? "" }
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
