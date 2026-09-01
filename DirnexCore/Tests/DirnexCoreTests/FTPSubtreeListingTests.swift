import Foundation
import Testing

@testable import DirnexCore

/// FTP's subtree shortcut: every entry beneath a folder, gathered one **level** per connection
/// rather than one directory per connection (docs/HISTORY.md ▸ After M19).
///
/// The claims split in two, and both halves are needed. What the shortcut *answers* has to be
/// indistinguishable from what the walk would have produced — the seam's own requirement, and the
/// reason `entriesAreIndistinguishableFromTheWalk` compares against a walk rather than against a
/// literal. What it *costs* is the whole point of the feature and is invisible in the answer, so
/// `listsOneLevelPerRequest` reads the batches: a version that walked would pass every other test
/// here.
@Suite("FTP subtree listing")
struct FTPSubtreeListingTests {
    private let location = FTPLocation(host: "ftp.example.com", username: "sa")

    /// ```
    /// /pub
    ///   docs/            report.txt, images/  (images/ holds one file)
    ///   notes.txt
    ///   link -> docs     a symlink to a directory
    /// ```
    private func makeBackend() -> (FTPBackend, FakeFTPTransport) {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = [
            "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 docs",
            "-rw-r--r-- 1 sa users    6 Jul 25 20:55 notes.txt",
            "lrwxrwxrwx 1 sa users    4 Jul 25 20:55 link -> docs"
        ].joined(separator: "\n")
        transport.listings["/pub/docs"] = [
            "-rw-r--r-- 1 sa users  120 Jul 25 20:56 report.txt",
            "drwxr-xr-x 2 sa users 4096 Jul 25 20:56 images"
        ].joined(separator: "\n")
        transport.listings["/pub/docs/images"] = "-rw-r--r-- 1 sa users 900 Jul 25 20:57 photo.jpg"
        return (FTPBackend(location: location, transport: transport), transport)
    }

    private func path(_ remotePath: String) -> VFSPath {
        VFSPath(backend: .ftp(location), path: remotePath)
    }

    /// The plain walk, written out by hand rather than borrowed from `SubtreeSearch`, so the
    /// comparison below is against the *rule* ("list each directory, recurse into the directory
    /// rows") and not against a second caller of the code under test.
    private func walk(from root: VFSPath, using backend: FTPBackend) throws -> [FileEntry] {
        var found: [FileEntry] = []
        var queue = [root]
        var head = 0
        while head < queue.count {
            let directory = queue[head]
            head += 1
            guard let entries = try? backend.listDirectory(at: directory) else { continue }
            for entry in entries {
                found.append(entry)
                if entry.isDirectory { queue.append(entry.path) }
            }
        }
        return found
    }

    @Test("answers the whole subtree, shallowest first")
    func answersTheWholeSubtree() throws {
        let (backend, _) = makeBackend()
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(listing.isComplete)
        #expect(listing.entries.map(\.path.path) == [
            "/pub/docs",
            "/pub/notes.txt",
            "/pub/link",
            "/pub/docs/report.txt",
            "/pub/docs/images",
            "/pub/docs/images/photo.jpg"
        ])
    }

    /// The cost claim, and the only test here a walking implementation would fail. Three levels,
    /// three requests — never six, which is what one-per-directory would be.
    @Test("lists one level per request, not one directory per request")
    func listsOneLevelPerRequest() throws {
        let (backend, transport) = makeBackend()
        _ = try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        #expect(transport.listedBatches == [
            ["/pub"],
            ["/pub/docs"],
            ["/pub/docs/images"]
        ])
    }

    /// A wider level is still one request. Written separately from the depth case because the two
    /// are what the batch is *for*: depth costs rounds and width does not.
    @Test("a level of several directories is one request")
    func aWideLevelIsOneRequest() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = (0..<5)
            .map { "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 d\($0)" }
            .joined(separator: "\n")
        for index in 0..<5 {
            transport.listings["/pub/d\(index)"] = "-rw-r--r-- 1 sa users 1 Jul 25 20:55 f.txt"
        }
        let backend = FTPBackend(location: location, transport: transport)
        _ = try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        #expect(transport.listedBatches.count == 2)
        #expect(
            transport.listedBatches.last == ["/pub/d0", "/pub/d1", "/pub/d2", "/pub/d3", "/pub/d4"]
        )
    }

    /// The seam's own requirement: the caller renders these beside hits from backends that walked,
    /// so a difference in paths, names, kinds or sizes would show as a wrong row rather than as a
    /// failure.
    @Test("entries are indistinguishable from the walk's")
    func entriesAreIndistinguishableFromTheWalk() throws {
        let (backend, _) = makeBackend()
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        let walked = try walk(from: path("/pub"), using: backend)
        #expect(Set(listing.entries.map(\.path.path)) == Set(walked.map(\.path.path)))
        for entry in listing.entries {
            let match = try #require(walked.first { $0.path == entry.path })
            #expect(entry == match)
        }
    }

    /// A permission gap below the root is ordinary, and everything found elsewhere is still a real
    /// answer — the walk's rule, which the shortcut has to share or it would prune whole branches
    /// the walk reports.
    @Test("an unreadable subdirectory is skipped rather than fatal")
    func anUnreadableSubdirectoryIsSkipped() throws {
        let (backend, transport) = makeBackend()
        transport.unlistablePaths = ["/pub/docs"]
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(listing.isComplete)
        // The row for `docs` is still there — it was listed *in* `/pub`, which succeeded. What is
        // missing is only what could not be read.
        #expect(listing.entries.map(\.path.path) == ["/pub/docs", "/pub/notes.txt", "/pub/link"])
    }

    /// The opposite rule one level up, and the reason the two cannot share a branch: the root is not
    /// a subdirectory, so a listing that fails there means there is no shortcut rather than a gap in
    /// one. `nil` hands it back to the walk, which lists the root itself and throws the server's own
    /// reason; answering an empty, complete subtree would report an unreadable folder as an empty
    /// one.
    @Test("an unreadable root is no shortcut, never an empty subtree")
    func anUnreadableRootIsNoShortcut() throws {
        let (backend, transport) = makeBackend()
        transport.unlistablePaths = ["/pub"]
        #expect(try backend.subtreeListing(at: path("/pub"), isCancelled: { false }) == nil)
    }

    /// The distinction the whole transport contract rests on: an empty directory answers with an
    /// empty listing and is complete, where an unreadable one answers `nil`. Conflating them would
    /// make every empty folder look like a refusal, or every refusal like an empty folder.
    @Test("an empty directory is not an unreadable one")
    func anEmptyDirectoryIsNotAnUnreadableOne() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 hollow"
        transport.listings["/pub/hollow"] = ""
        let backend = FTPBackend(location: location, transport: transport)
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(listing.isComplete)
        #expect(listing.entries.map(\.path.path) == ["/pub/hollow"])
    }

    /// `kind == .directory`, never `isDirectoryLike`. The walk recurses on exactly this, so a
    /// symlink is a row and not a branch — which is also what makes a cycle through a link back up
    /// the tree unreachable, since nothing here would otherwise bound it.
    @Test("a symlink to a directory is a row, not a branch")
    func symlinksAreRowsNotBranches() throws {
        let (backend, transport) = makeBackend()
        _ = try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        #expect(!transport.listedBatches.joined().contains("/pub/link"))
    }

    /// Being cut off is reported, never swallowed: a search would otherwise answer "here is
    /// everything" about part of a tree, and the sizer would report a total that is simply wrong.
    @Test("stops at the row limit and says so")
    func stopsAtTheRowLimit() throws {
        var (backend, _) = makeBackend()
        backend.subtreeRowLimit = 3
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(!listing.isComplete)
        #expect(listing.entries.count == 3)
    }

    @Test("cancellation travels rather than being answered as a short subtree")
    func cancellationTravels() {
        let (backend, _) = makeBackend()
        #expect(throws: CancellationError.self) {
            _ = try backend.subtreeListing(at: path("/pub"), isCancelled: { true })
        }
    }

    /// A transport failure withdraws the shortcut instead of failing the caller: the walk is
    /// standing right behind it and will surface a real error with a real reason if there is one.
    @Test("a transport failure is no shortcut rather than a failure")
    func aTransportFailureIsNoShortcut() throws {
        let (backend, transport) = makeBackend()
        transport.error = .timedOut
        #expect(try backend.subtreeListing(at: path("/pub"), isCancelled: { false }) == nil)
    }

    /// One answer per request, in order, is the whole contract — a transport that answered some
    /// other number has told us nothing that can be attributed to a directory.
    @Test("answers of a different length are no shortcut")
    func mismatchedAnswerCountIsNoShortcut() throws {
        let transport = MiscountingFTPTransport()
        transport.listings["/pub"] = [
            "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 a",
            "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 b"
        ].joined(separator: "\n")
        let backend = FTPBackend(location: location, transport: transport)
        #expect(try backend.subtreeListing(at: path("/pub"), isCancelled: { false }) == nil)
    }

    /// Through an **existential**, which is how the app actually holds it: `CompositeBackend` routes
    /// to `any VFSBackend`, so what has to answer is the witness in the conformance table rather
    /// than whatever a concrete call binds to. The implementation lives in an extension of the type,
    /// and a witness that failed to land there would leave the protocol's `nil` default in its
    /// place — a whole feature that silently never runs, which is the failure shape this project has
    /// already paid for twice (docs/NOTES.md ▸ the `WKNavigationDelegate` witness, and M22's
    /// unforwarded seam).
    @Test("the shortcut answers through `any VFSBackend`, not the protocol's default")
    func answersThroughTheExistential() throws {
        let (backend, _) = makeBackend()
        let erased: any VFSBackend = backend
        let listing = try #require(
            try erased.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(listing.entries.count == 6)
    }

    @Test("a backend refuses a path that is not its own")
    func refusesAForeignPath() {
        let (backend, _) = makeBackend()
        #expect(throws: (any Error).self) {
            _ = try backend.subtreeListing(at: .local("/tmp"), isCancelled: { false })
        }
    }

    /// The additive default, exercised on a transport that has not implemented the batch: the
    /// answers are the same answers, so such a transport is slow and never wrong. Without this the
    /// forwarding half is only ever reached by a caller nobody wrote.
    @Test("a transport that cannot batch still answers the whole subtree")
    func theForwardingDefaultAnswersTheSameSubtree() throws {
        let unbatched = UnbatchedFTPTransport()
        unbatched.listings["/pub"] = [
            "drwxr-xr-x 2 sa users 4096 Jul 25 20:55 docs",
            "-rw-r--r-- 1 sa users    6 Jul 25 20:55 notes.txt"
        ].joined(separator: "\n")
        unbatched.listings["/pub/docs"] = "-rw-r--r-- 1 sa users 120 Jul 25 20:56 report.txt"
        unbatched.unlistablePaths = ["/pub/locked"]
        let backend = FTPBackend(location: location, transport: unbatched)
        let listing = try #require(
            try backend.subtreeListing(at: path("/pub"), isCancelled: { false })
        )
        #expect(listing.isComplete)
        #expect(
            listing.entries.map(\.path.path) == [
                "/pub/docs",
                "/pub/notes.txt",
                "/pub/docs/report.txt"
            ]
        )
        // The forwarding really is one call per directory — which is what makes it correct and slow
        // rather than correct and fast.
        #expect(unbatched.listedPaths == ["/pub", "/pub/docs"])
    }

    @Test("the forwarding default reads a refusal as `nil`, not as an empty directory")
    func theForwardingDefaultReportsARefusalAsNil() throws {
        let unbatched = UnbatchedFTPTransport()
        unbatched.unlistablePaths = ["/pub/locked"]
        let answers = try unbatched.listDirectories(["/pub/locked"], isCancelled: { false })
        #expect(answers == [nil])
    }

    @Test("the forwarding default lets cancellation travel")
    func theForwardingDefaultLetsCancellationTravel() {
        let unbatched = UnbatchedFTPTransport()
        #expect(throws: CancellationError.self) {
            _ = try unbatched.listDirectories(["/pub"], isCancelled: { true })
        }
    }
}

// MARK: - Doubles

/// A transport with **no** batch of its own, so every call through it takes the protocol's
/// forwarding default. Deliberately a second type rather than a flag on `FakeFTPTransport`: which
/// implementation runs is settled by conformance at compile time, so a flag could not reach it.
private final class UnbatchedFTPTransport: FTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var unlistablePaths: Set<String> = []
    private(set) var listedPaths: [String] = []

    func listDirectory(_ remotePath: String) throws -> String {
        if unlistablePaths.contains(remotePath) { throw FTPTransportError.permissionDenied }
        listedPaths.append(remotePath)
        return listings[remotePath] ?? ""
    }

    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func fileSize(_ remotePath: String) throws -> Int64 { 0 }
    func fetchCertificate() throws -> FTPCertificate { throw FTPTransportError.failure("") }

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

/// A transport that answers a batch with the wrong number of listings — the one shape the backend
/// cannot attribute to a directory, and which no real `curl` run produces, so it needs a double of
/// its own to be reachable at all.
private final class MiscountingFTPTransport: FTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]

    func listDirectory(_ remotePath: String) throws -> String { listings[remotePath] ?? "" }

    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        remotePaths.isEmpty ? [] : remotePaths.map { listings[$0] ?? "" } + [nil]
    }

    func makeDirectory(_ remotePath: String) throws {}
    func createEmptyFile(_ remotePath: String) throws {}
    func rename(_ source: String, to destination: String) throws {}
    func removeFile(_ remotePath: String) throws {}
    func removeDirectory(_ remotePath: String) throws {}
    func fileSize(_ remotePath: String) throws -> Int64 { 0 }
    func fetchCertificate() throws -> FTPCertificate { throw FTPTransportError.failure("") }

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
