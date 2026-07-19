import Foundation
import Testing

@testable import DirnexCore

@Suite("SFTPBackend")
struct SFTPBackendTests {
    private let location = SFTPLocation(host: "example.com", port: 22, username: "oleg")

    private func backend(_ transport: FakeSFTPTransport) -> SFTPBackend {
        SFTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: remote)
    }

    @Test("reports its account as identity and is writable but Trash-less and clone-less")
    func identityAndCapabilities() {
        let sut = backend(FakeSFTPTransport())
        #expect(sut.id == .sftp(location))
        #expect(sut.capabilities == [.read, .write, .rename])
        #expect(!sut.capabilities.contains(.trash))
        #expect(!sut.capabilities.contains(.clone))
        // Writable + Trash-less → a delete degrades to a confirmed permanent delete (PLAN.md §M5).
        #expect(sut.capabilities(for: path("/home/oleg")).deleteStrategy == .permanent)
    }

    @Test("lists a remote directory into FileEntry rows, dropping . and .. with child paths")
    func listsDirectory() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/..
        -rw-r--r--    ? oleg staff  128 Jul 13 00:09 /home/oleg/notes.txt
        drwxr-xr-x    ? oleg staff   64 Jul 13 00:09 /home/oleg/photos
        """
        let entries = try backend(transport).listDirectory(at: path("/home/oleg"))
        #expect(entries.count == 2) // . and .. filtered out

        let notes = try #require(entries.first { $0.name == "notes.txt" })
        #expect(notes.kind == .file)
        #expect(notes.byteSize == 128)
        #expect(notes.path == path("/home/oleg/notes.txt"))

        let photos = try #require(entries.first { $0.name == "photos" })
        #expect(photos.isDirectory)
        #expect(photos.path == path("/home/oleg/photos"))
    }

    @Test("stats a directory from its self '.' row, named for the queried path")
    func statsDirectoryFromDotRow() throws {
        let transport = FakeSFTPTransport()
        // `ls -la <dir>` returns the directory's children plus its self `.` row.
        transport.listings["/home/oleg/docs"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/docs/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/docs/..
        -rw-r--r--    ? oleg staff   10 Jul 13 00:09 /home/oleg/docs/a.txt
        """
        let entry = try backend(transport).stat(at: path("/home/oleg/docs"))
        #expect(entry.name == "docs")
        #expect(entry.kind == .directory)
        #expect(entry.path == path("/home/oleg/docs"))
        #expect(entry.byteSize == 192) // the '.' row's own size, not a child's
    }

    @Test("stats a file from its single row")
    func statsFileFromSingleRow() throws {
        let transport = FakeSFTPTransport()
        // `ls -la <file>` returns just the file's row (no '.'/'..').
        transport.listings["/home/oleg/notes.txt"] =
            "-rw-r--r--    ? oleg staff 42 Jul 13 00:09 /home/oleg/notes.txt"
        let entry = try backend(transport).stat(at: path("/home/oleg/notes.txt"))
        #expect(entry.name == "notes.txt")
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 42)
        #expect(entry.path == path("/home/oleg/notes.txt"))
    }

    @Test("a stat that parses to nothing is a not-found")
    func statEmptyIsNotFound() {
        let transport = FakeSFTPTransport()
        transport.listings["/gone"] = ""
        #expect(throws: VFSError.notFound(path("/gone"))) {
            try backend(transport).stat(at: path("/gone"))
        }
    }

    @Test("maps a transport not-found to VFSError.notFound with the queried path")
    func mapsNotFound() {
        let transport = FakeSFTPTransport()
        transport.error = .notFound
        #expect(throws: VFSError.notFound(path("/missing"))) {
            try backend(transport).listDirectory(at: path("/missing"))
        }
    }

    @Test("maps a transport permission failure to VFSError.permissionDenied")
    func mapsPermissionDenied() {
        let transport = FakeSFTPTransport()
        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(path("/root"))) {
            try backend(transport).listDirectory(at: path("/root"))
        }
    }

    @Test("maps a generic transport failure to VFSError.io")
    func mapsGenericFailure() {
        let transport = FakeSFTPTransport()
        transport.error = .failure("connection reset")
        #expect(throws: VFSError.io(path: path("/x"), code: EIO)) {
            try backend(transport).listDirectory(at: path("/x"))
        }
    }

    @Test("rejects a path that belongs to another backend")
    func rejectsForeignPath() {
        let sut = backend(FakeSFTPTransport())
        #expect(throws: (any Error).self) {
            try sut.listDirectory(at: .local("/etc"))
        }
        let other = VFSPath(backend: .sftp(SFTPLocation(host: "other", username: "x")), path: "/")
        #expect(throws: (any Error).self) {
            try sut.stat(at: other)
        }
    }
}

// The write primitives, split into an extension so the suite stays under SwiftLint's
// type-body-length limit (a recurring gotcha in this project).
extension SFTPBackendTests {
    // MARK: - Writes

    @Test("createDirectory calls mkdir and maps a permission failure")
    func createsDirectory() throws {
        let transport = FakeSFTPTransport()
        try backend(transport).createDirectory(at: path("/home/oleg/new"))
        #expect(transport.madeDirectories == ["/home/oleg/new"])

        transport.error = .permissionDenied
        #expect(throws: VFSError.permissionDenied(path("/home/oleg/nope"))) {
            try backend(transport).createDirectory(at: path("/home/oleg/nope"))
        }
    }

    @Test("moveItem renames within the account")
    func movesWithinAccount() throws {
        let transport = FakeSFTPTransport()
        try backend(transport).moveItem(at: path("/home/oleg/a"), to: path("/home/oleg/b"))
        #expect(transport.renames.count == 1)
        #expect(transport.renames[0].0 == "/home/oleg/a")
        #expect(transport.renames[0].1 == "/home/oleg/b")
    }

    @Test("a cross-backend move throws EXDEV so the engine falls back to copy+delete")
    func crossBackendMoveThrowsEXDEV() {
        let transport = FakeSFTPTransport()
        #expect(throws: VFSError.io(path: path("/home/oleg/a"), code: EXDEV)) {
            try backend(transport).moveItem(at: path("/home/oleg/a"), to: .local("/tmp/a"))
        }
        #expect(transport.renames.isEmpty) // never attempted a remote rename
    }

    @Test("removeItem removes a file via rm, classified from its parent listing")
    func removesFile() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/..
        -rw-r--r--    ? oleg staff  128 Jul 13 00:09 /home/oleg/notes.txt
        """
        try backend(transport).removeItem(at: path("/home/oleg/notes.txt"))
        #expect(transport.removedFiles == ["/home/oleg/notes.txt"])
        #expect(transport.removedDirectories.isEmpty)
    }

    @Test("removeItem empties a directory depth-first, then rmdirs it")
    func removesDirectoryRecursively() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/..
        drwxr-xr-x    ? oleg staff   96 Jul 13 00:09 /home/oleg/target
        """
        transport.listings["/home/oleg/target"] = """
        drwxr-xr-x    ? oleg staff   96 Jul 13 00:09 /home/oleg/target/.
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/target/..
        -rw-r--r--    ? oleg staff   10 Jul 13 00:09 /home/oleg/target/a.txt
        drwxr-xr-x    ? oleg staff   64 Jul 13 00:09 /home/oleg/target/sub
        """
        transport.listings["/home/oleg/target/sub"] = """
        drwxr-xr-x    ? oleg staff   64 Jul 13 00:09 /home/oleg/target/sub/.
        drwxr-xr-x    ? oleg staff   96 Jul 13 00:09 /home/oleg/target/sub/..
        -rw-r--r--    ? oleg staff    5 Jul 13 00:09 /home/oleg/target/sub/b.txt
        """
        try backend(transport).removeItem(at: path("/home/oleg/target"))
        #expect(transport.removedFiles == ["/home/oleg/target/a.txt", "/home/oleg/target/sub/b.txt"])
        // Children before parents: the nested dir is rmdir'd before the top one.
        #expect(transport.removedDirectories == ["/home/oleg/target/sub", "/home/oleg/target"])
    }

    @Test("removeItem deletes a symlink itself, never following it into a directory")
    func removesSymlinkWithoutFollowing() throws {
        let transport = FakeSFTPTransport()
        transport.listings["/home/oleg"] = """
        drwxr-xr-x    ? oleg staff  192 Jul 13 00:09 /home/oleg/.
        drwxr-xr-x    ? oleg staff 3072 Jul  9 10:00 /home/oleg/..
        lrwxr-xr-x    ? oleg staff    9 Jul 13 00:09 /home/oleg/latest
        """
        try backend(transport).removeItem(at: path("/home/oleg/latest"))
        #expect(transport.removedFiles == ["/home/oleg/latest"]) // rm the link, not rmdir a target
        #expect(transport.removedDirectories.isEmpty)
    }

    @Test("copyFile downloads a remote source to a local destination and reports its bytes")
    func copyFileDownloads() throws {
        let transport = FakeSFTPTransport()
        transport.downloadBytes = 128
        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: path("/home/oleg/notes.txt"),
            to: .local("/tmp/notes.txt"),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        #expect(transport.downloads.count == 1)
        #expect(transport.downloads[0].remote == "/home/oleg/notes.txt")
        #expect(transport.downloads[0].local == "/tmp/notes.txt")
        #expect(transport.uploads.isEmpty)
        #expect(reported == 128)
    }

    @Test("copyFile uploads a local source to a remote destination and reports its bytes")
    func copyFileUploads() throws {
        let transport = FakeSFTPTransport()
        transport.uploadBytes = 64
        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: .local("/tmp/report.txt"),
            to: path("/home/oleg/report.txt"),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        #expect(transport.uploads.count == 1)
        #expect(transport.uploads[0].local == "/tmp/report.txt")
        #expect(transport.uploads[0].remote == "/home/oleg/report.txt")
        #expect(transport.downloads.isEmpty)
        #expect(reported == 64)
    }

    @Test("copyFile refuses a remote-to-remote transfer it can't express")
    func copyFileRemoteToRemoteUnsupported() {
        let transport = FakeSFTPTransport()
        #expect(throws: (any Error).self) {
            try backend(transport).copyFile(
                at: path("/home/oleg/a"),
                to: path("/home/oleg/b"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.downloads.isEmpty && transport.uploads.isEmpty)
    }

    @Test("copyFile honours cancellation before transferring")
    func copyFileCancels() {
        let transport = FakeSFTPTransport()
        #expect(throws: CancellationError.self) {
            try backend(transport).copyFile(
                at: path("/home/oleg/notes.txt"),
                to: .local("/tmp/notes.txt"),
                progress: { _ in },
                isCancelled: { true }
            )
        }
        #expect(transport.downloads.isEmpty)
    }

    @Test("createSymbolicLink recreates a link on the remote")
    func createsSymbolicLink() throws {
        let transport = FakeSFTPTransport()
        try backend(transport).createSymbolicLink(
            at: path("/home/oleg/latest"),
            withDestination: "releases/1.2.0"
        )
        #expect(transport.symlinks.count == 1)
        #expect(transport.symlinks[0].link == "/home/oleg/latest")
        #expect(transport.symlinks[0].target == "releases/1.2.0")
    }

    @Test("all jobs on one host share a volume identifier")
    func volumeIdentifierPerHost() {
        let sut = backend(FakeSFTPTransport())
        let one = sut.volumeIdentifier(for: path("/a"))
        let two = sut.volumeIdentifier(for: path("/b/c"))
        #expect(one != nil)
        #expect(one == two)
    }
}

// Mid-file resume (`get -a`/`put -a`), split into its own extension to keep each type body under
// SwiftLint's limit (a recurring gotcha in this project).
extension SFTPBackendTests {
    // MARK: - Resume

    /// Write a temporary local file of `bytes` zero-filled bytes and return its path, so a test can
    /// stage a "partial" (a local download-in-progress or an upload source) on real disk.
    private func makeTempFile(bytes: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex_resume_\(UUID().uuidString).bin")
        try Data(count: bytes).write(to: url)
        return url.path
    }

    @Test("copyFile resumes a download when a local partial is a proper prefix (get -a)")
    func copyFileResumesDownload() throws {
        let transport = FakeSFTPTransport()
        // Remote source is 300 bytes; a local partial of 120 already sits at the destination.
        transport.listings["/home/oleg/big.bin"] =
            "-rw-r--r--    ? oleg staff 300 Jul 14 00:00 /home/oleg/big.bin"
        transport.downloadBytes = 300 // the total size a real `get -a` leaves on disk
        let localDest = try makeTempFile(bytes: 120)
        defer { try? FileManager.default.removeItem(atPath: localDest) }

        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: path("/home/oleg/big.bin"),
            to: .local(localDest),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        let download = try #require(transport.downloads.first)
        #expect(download.resume) // resumed, not restarted
        #expect(reported == 180) // only the remaining 300 - 120 bytes counted
    }

    @Test("copyFile resumes a large upload when a remote partial is a proper prefix (put -a)")
    func copyFileResumesUpload() throws {
        let transport = FakeSFTPTransport()
        let partial = 1 << 20 // remote already holds a 1 MiB prefix
        transport.listings["/home/oleg/big.bin"] =
            "-rw-r--r--    ? oleg staff \(partial) Jul 14 00:00 /home/oleg/big.bin"
        let sourceBytes = 2 << 20 // 2 MiB local source, over the resume-upload threshold
        let localSource = try makeTempFile(bytes: sourceBytes)
        defer { try? FileManager.default.removeItem(atPath: localSource) }
        transport.uploadBytes = Int64(sourceBytes)

        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: .local(localSource),
            to: path("/home/oleg/big.bin"),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        let upload = try #require(transport.uploads.first)
        #expect(upload.resume)
        #expect(reported == Int64(sourceBytes - partial)) // only the remaining 1 MiB counted
    }

    @Test("copyFile does not resume a small upload even with a remote partial (skips the stat)")
    func copyFileSmallUploadDoesNotResume() throws {
        let transport = FakeSFTPTransport()
        // A remote partial exists, but the source is tiny — resuming isn't worth a stat round trip.
        transport.listings["/home/oleg/small.bin"] =
            "-rw-r--r--    ? oleg staff 10 Jul 14 00:00 /home/oleg/small.bin"
        let localSource = try makeTempFile(bytes: 40)
        defer { try? FileManager.default.removeItem(atPath: localSource) }
        transport.uploadBytes = 40

        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: .local(localSource),
            to: path("/home/oleg/small.bin"),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        let upload = try #require(transport.uploads.first)
        #expect(!upload.resume) // full re-put, not a resume
        #expect(reported == 40) // whole file counted
    }

    @Test("copyFile does not resume a fresh download (no local partial, no remote stat)")
    func copyFileFreshDownloadDoesNotResume() throws {
        let transport = FakeSFTPTransport()
        transport.downloadBytes = 128
        let localDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex_fresh_\(UUID().uuidString).bin").path
        var reported: Int64 = 0
        try backend(transport).copyFile(
            at: path("/home/oleg/notes.txt"),
            to: .local(localDest),
            progress: { reported += $0 },
            isCancelled: { false }
        )
        let download = try #require(transport.downloads.first)
        #expect(!download.resume)
        #expect(reported == 128)
    }
}

/// A canned `SFTPTransport`: returns per-path `ls -la` text and records every write call (or throws
/// a configured error), so the backend's browse *and* write logic is exercised without a live
/// server (PLAN.md §2 "the app is a thin client").
private final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var error: SFTPTransportError?

    // Recorded write calls, in the order the backend issued them.
    private(set) var madeDirectories: [String] = []
    private(set) var renames: [(String, String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [String] = []
    private(set) var symlinks: [(link: String, target: String)] = []
    private(set) var downloads: [RecordedTransfer] = []
    private(set) var uploads: [RecordedTransfer] = []

    /// One recorded `get`/`put`, carrying both endpoints and the resume flag (a struct rather than a
    /// tuple to stay under SwiftLint's two-member `large_tuple` limit).
    struct RecordedTransfer {
        let local: String
        let remote: String
        let resume: Bool
    }

    // Byte counts the transfer methods report back for progress accounting.
    var downloadBytes: Int64 = 0
    var uploadBytes: Int64 = 0

    func listDirectory(_ remotePath: String) throws -> String {
        if let error { throw error }
        return listings[remotePath] ?? ""
    }

    func makeDirectory(_ remotePath: String) throws {
        if let error { throw error }
        madeDirectories.append(remotePath)
    }

    func rename(_ source: String, to destination: String) throws {
        if let error { throw error }
        renames.append((source, destination))
    }

    func removeFile(_ remotePath: String) throws {
        if let error { throw error }
        removedFiles.append(remotePath)
    }

    func removeDirectory(_ remotePath: String) throws {
        if let error { throw error }
        removedDirectories.append(remotePath)
    }

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        if let error { throw error }
        symlinks.append((remotePath, target))
    }

    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64 {
        if let error { throw error }
        downloads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return downloadBytes
    }

    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64 {
        if let error { throw error }
        uploads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return uploadBytes
    }
}
