import Foundation
import Testing

@testable import DirnexCore

/// SFTP's ``VFSBackend/listDirectories(at:isCancelled:)``: the folders a tree refresh re-lists, in
/// one `sftp` session instead of one each.
///
/// Modeled on `FTPBatchedListingTests`, and split the same way. What it *answers* must be what
/// listing each folder would have answered, which `answersWhatEachListingWould` compares against
/// exactly that. What it *costs* is the point and is invisible in the answers, so the transport
/// records every batch and every single listing — a version that looped would pass every answer
/// test here and fail `listsSeveralFoldersInOneSession`.
@Suite("SFTP batched listing")
struct SFTPBatchedListingTests {
    private let location = SFTPLocation(host: "example.com", username: "sa")

    /// A tree with two folders open under its root.
    private let folders = ["/home/sa", "/home/sa/inbox", "/home/sa/inbox/today"]

    private func makeBackend() -> (SFTPBackend, ScriptedSFTPTransport) {
        let transport = ScriptedSFTPTransport()
        transport.listings["/home/sa"] = ScriptedSFTPTransport.rows(
            in: "/home/sa", ["drwxr-xr-x    ? sa  users  4096 Jun 14  2024 inbox"]
        )
        transport.listings["/home/sa/inbox"] = ScriptedSFTPTransport.rows(
            in: "/home/sa/inbox", ["drwxr-xr-x    ? sa  users  4096 Oct 19 14:36 today"]
        )
        transport.listings["/home/sa/inbox/today"] = ScriptedSFTPTransport.rows(
            in: "/home/sa/inbox/today", [
                "-rw-r--r--    ? sa  users  876544 Oct 19 01:00 report.xml",
                "-rw-r--r--    ? sa  users 2936012 Oct 19 14:36 written-just-now.xml"
            ]
        )
        return (SFTPBackend(location: location, transport: transport), transport)
    }

    private func paths(_ remotePaths: [String]) -> [VFSPath] {
        remotePaths.map { VFSPath(backend: .sftp(location), path: $0) }
    }

    @Test("lists several folders in one session")
    func listsSeveralFoldersInOneSession() throws {
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
        // Not vacuous: the file a refresh exists to show is among them, under its own folder.
        #expect(
            answers[2]?.map(\.path.path).contains("/home/sa/inbox/today/written-just-now.xml") == true
        )
    }

    /// A tree with nothing open, and list mode: a batch of one is one session either way.
    @Test("one folder takes the single listing")
    func oneFolderTakesTheSingleListing() throws {
        let (backend, transport) = makeBackend()
        let answers = try backend.listDirectories(
            at: paths(["/home/sa/inbox/today"]), isCancelled: { false }
        )
        #expect(answers.first??.count == 2)
        #expect(transport.batches.isEmpty)
        #expect(transport.singleAttempts == ["/home/sa/inbox/today"])
    }

    /// A folder the server will not list — a permission gap, or one deleted since it was opened —
    /// is an answer about that folder from a session that worked, so it costs no further session
    /// and does not cost the others their rows.
    @Test("a refused folder answers nil and the rest still land, without another session")
    func refusedFolderAnswersNil() throws {
        let (backend, transport) = makeBackend()
        transport.refused = ["/home/sa/inbox"]
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
        transport.listings["/home/sa/inbox/today"] = ScriptedSFTPTransport.rows(
            in: "/home/sa/inbox/today", []
        )
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers[2] == [])
    }

    /// A batch whose session never got in, while a single listing does — the folders are still
    /// listed, one at a time.
    @Test("a batch that lands nothing falls back to one listing per folder")
    func emptyBatchFallsBackToSingleListings() throws {
        let (backend, transport) = makeBackend()
        transport.batchSessionRefused = true
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

    /// The guard on the fallback: a server refusing us *altogether* empties the batch too, and must
    /// then be asked once more — not once per folder, every round.
    @Test("a server refusing the login is asked once more, not once per folder")
    func refusingServerIsAskedOnce() throws {
        let (backend, transport) = makeBackend()
        transport.batchSessionRefused = true
        transport.refused = Set(folders)
        let answers = try backend.listDirectories(at: paths(folders), isCancelled: { false })
        #expect(answers == [nil, nil, nil])
        #expect(transport.singleAttempts == ["/home/sa"])
    }

    @Test("a folder on another connection is refused before anything reaches the wire")
    func foreignFolderIsRefused() {
        let (backend, transport) = makeBackend()
        let elsewhere = VFSPath(
            backend: .sftp(SFTPLocation(host: "other.example.com", username: "sa")), path: "/"
        )
        #expect(throws: VFSError.self) {
            _ = try backend.listDirectories(at: paths(["/home/sa"]) + [elsewhere], isCancelled: {
                false
            })
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

    /// The transport's forwarding default, which a transport without the verb takes: the same
    /// answers, one session per folder.
    @Test("a transport without the verb lists each folder, and answers nil for a refused one")
    func forwardingDefaultListsEachFolder() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/a"] = ScriptedSFTPTransport.rows(
            in: "/a", ["-rw-r--r--    ? sa  users  3 Oct 19 01:00 one.txt"]
        )
        transport.listings["/b"] = ScriptedSFTPTransport.rows(in: "/b", [])
        let answers = try transport.listDirectories(["/a", "/b"], isCancelled: { false })
        #expect(answers.map { $0.map { SFTPListingParser.parse($0).map(\.name) } } == [
            [".", "..", "one.txt"], [".", ".."]
        ])

        transport.error = .permissionDenied
        #expect(try transport.listDirectories(["/a"], isCancelled: { false }) == [nil])
        #expect(throws: CancellationError.self) {
            _ = try transport.listDirectories(["/a"], isCancelled: { true })
        }
    }
}

// MARK: - Double

/// A transport that plays what `sftp` really prints for a batch — each line's `sftp> ` echo, then a
/// folder's rows or its refusal, then the end marker — and reads it back through the shipped
/// ``SFTPBatchListing``, which is what the app's transport does with a real session. The batch and
/// the single listing can fail independently, which no shared flag on `FakeSFTPTransport` can
/// express, and **every attempt** is recorded, refused ones included, so a test can count the
/// sessions a failing server was asked for.
private final class ScriptedSFTPTransport: SFTPTransport, @unchecked Sendable {
    /// Each folder's `ls -la` rows, `.` and `..` included, as `sftp` prints them.
    var listings: [String: String] = [:]
    /// Folders the server refuses, in a batch and singly alike.
    var refused: Set<String> = []
    /// A batch whose session never got in — what a key the server no longer accepts prints.
    var batchSessionRefused = false
    var batchThrows = false
    private(set) var batches: [[String]] = []
    private(set) var singleAttempts: [String] = []

    /// `sftp`'s rows for `folder`: its `.` and `..`, then `children` with the full path `sftp`
    /// prints in place of the bare name.
    static func rows(in folder: String, _ children: [String]) -> String {
        let own = [
            "drwxr-xr-x    ? sa  users  4096 Oct 19 14:36 \(folder)/.",
            "drwxr-xr-x    ? sa  users  4096 Oct 19 14:36 \(folder)/.."
        ]
        let named = children.map { row -> String in
            let name = row.split(separator: " ").last.map(String.init) ?? row
            return String(row.dropLast(name.count)) + "\(folder)/\(name)"
        }
        return (own + named).joined(separator: "\n")
    }

    func listDirectory(_ remotePath: String) throws -> String {
        singleAttempts.append(remotePath)
        if refused.contains(remotePath) { throw SFTPTransportError.permissionDenied }
        return listings[remotePath] ?? ""
    }

    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        guard !isCancelled() else { throw CancellationError() }
        batches.append(remotePaths)
        if batchThrows { throw SFTPTransportError.failure("batch") }
        return SFTPBatchListing.answers(in: transcript(for: remotePaths), for: remotePaths)
    }

    /// The session `sftp` would have printed for this batch, standard error folded in.
    private func transcript(for remotePaths: [String]) -> String {
        if batchSessionRefused {
            return "sa@example.com: Permission denied (publickey).\r\nConnection closed\r\n"
        }
        var folders = remotePaths.filter(SFTPBatchListing.canFrame).makeIterator()
        let printed = SFTPBatchListing.script(for: remotePaths)
            .split(separator: "\n")
            .flatMap { line -> [String] in
                guard line != SFTPBatchListing.endMarker, let folder = folders.next() else {
                    return ["sftp> \(line)", "Remote working directory: /home/sa"]
                }
                let output = refused.contains(folder)
                    ? "remote readdir(\"\(folder)/\"): Permission denied\r"
                    : listings[folder] ?? ""
                return ["sftp> \(line)", output]
            }
        return printed.joined(separator: "\n")
    }

    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func createSymbolicLink(_ remotePath: String, target: String) throws {}

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
