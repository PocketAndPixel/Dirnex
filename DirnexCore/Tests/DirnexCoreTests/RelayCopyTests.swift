import Foundation
import Testing

@testable import DirnexCore

/// The staged copy between two backends that can each only talk to this machine (docs/HISTORY.md ▸ After M19).
///
/// SFTP and FTP have no copy verb — their transfer is an upload or a download — so a pair of ends
/// with no local side has no expression in either backend, which is what made F5 from a bucket to a
/// server (and a duplicate *within* one SFTP account) fail per file. `RelayCopy` is the download →
/// upload → delete that a caller holding both connections can run and neither backend can.
///
/// The fakes below are shaped like the real remote backends in the one way that matters here: each
/// serves a transfer with **one end on the local disk** and refuses anything else, so a relay that
/// quietly handed a pair to one backend would fail rather than pass.
@Suite("RelayCopy: staged remote-to-remote transfer")
struct RelayCopyTests {
    private static let alpha = VFSBackendID("test-alpha")
    private static let beta = VFSBackendID("test-beta")

    private func remotePath(_ backend: VFSBackendID, _ path: String) -> VFSPath {
        VFSPath(backend: backend, path: path)
    }

    // MARK: - The transfer

    @Test("bytes land on the second account, and the first is untouched")
    func relaysBetweenTwoAccounts() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let payload = Data("the quick brown fox".utf8)
        let source = FakeRemote(id: Self.alpha, files: ["/pub/fox.txt": payload])
        let destination = FakeRemote(id: Self.beta)

        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/pub/fox.txt"), on: source),
            to: .init(remotePath(Self.beta, "/home/u/fox.txt"), on: destination),
            stagingRoot: tree.root,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(destination.contents(of: "/home/u/fox.txt") == payload)
        #expect(source.contents(of: "/pub/fox.txt") == payload)
        #expect(source.downloads == 1)
        #expect(destination.uploads == 1)
    }

    @Test("a duplicate inside one account is relayed too — SFTP and FTP have no copy verb")
    func relaysWithinOneAccount() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let payload = Data("same server, two folders".utf8)
        let account = FakeRemote(id: Self.alpha, files: ["/a/note.txt": payload])

        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/a/note.txt"), on: account),
            to: .init(remotePath(Self.alpha, "/b/note.txt"), on: account),
            stagingRoot: tree.root,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(account.contents(of: "/b/note.txt") == payload)
    }

    // MARK: - Progress

    /// The queue's denominator is the file's size, so the two legs must together report it **once**.
    /// Reporting each leg in full would drive the bar to 200 %, which is what makes this the
    /// assertion the halving exists for.
    @Test("the two legs report the file once, forward-only, summing to its exact size")
    func countsTheFileOnce() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let payload = Data(repeating: UInt8(ascii: "x"), count: 4096)
        let source = FakeRemote(id: Self.alpha, files: ["/big.bin": payload])
        let destination = FakeRemote(id: Self.beta)

        var deltas: [Int64] = []
        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/big.bin"), on: source),
            to: .init(remotePath(Self.beta, "/big.bin"), on: destination),
            stagingRoot: tree.root,
            progress: { deltas.append($0) },
            isCancelled: { false }
        )

        let reported = deltas.reduce(0, +)
        #expect(reported == 4096)
        let allForward = deltas.allSatisfy { $0 > 0 }
        #expect(allForward)
        #expect(deltas.count > 1) // it moved while it ran, rather than reporting once at the end
    }

    /// An SFTP upload has no observable at all — `sftp` prints no meter a spawned process can read
    /// — so the second leg can legitimately report nothing until it is done. The count still has to
    /// settle on the file's size, which is the tail's job rather than the estimates'.
    @Test("an upload that reports nothing still ends on the exact byte count")
    func silentUploadStillSettlesExactly() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let payload = Data(repeating: UInt8(ascii: "y"), count: 4096)
        let source = FakeRemote(id: Self.alpha, files: ["/quiet.bin": payload])
        let destination = FakeRemote(id: Self.beta)
        destination.reportsUploadProgress = false

        var reported: Int64 = 0
        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/quiet.bin"), on: source),
            to: .init(remotePath(Self.beta, "/quiet.bin"), on: destination),
            stagingRoot: tree.root,
            progress: { reported += $0 },
            isCancelled: { false }
        )

        #expect(reported == 4096)
        #expect(destination.contents(of: "/quiet.bin") == payload)
    }

    // MARK: - The staged copy

    @Test("the staged copy is deleted when the transfer succeeds")
    func cleansUpAfterSuccess() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let source = FakeRemote(id: Self.alpha, files: ["/a.txt": Data("a".utf8)])

        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/a.txt"), on: source),
            to: .init(remotePath(Self.beta, "/a.txt"), on: FakeRemote(id: Self.beta)),
            stagingRoot: tree.root,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(try stagingRootIsEmpty(tree))
    }

    /// The failing half is the one worth pinning: a relay that leaked its staged copy would leave a
    /// whole file per failure in a temp directory nobody looks at.
    @Test("the staged copy is deleted when the upload fails, and the failure is the one reported")
    func cleansUpAfterFailure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let source = FakeRemote(id: Self.alpha, files: ["/a.txt": Data("a".utf8)])
        let destination = FakeRemote(id: Self.beta)
        let target = remotePath(Self.beta, "/a.txt")
        destination.uploadFailure = .permissionDenied(target)

        #expect(throws: VFSError.permissionDenied(target)) {
            try RelayCopy.copyFile(
                from: .init(remotePath(Self.alpha, "/a.txt"), on: source),
                to: .init(target, on: destination),
                stagingRoot: tree.root,
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(try stagingRootIsEmpty(tree))
    }

    @Test("a cancel between the legs uploads nothing and leaves no staged copy")
    func cancelsBetweenLegs() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let source = FakeRemote(id: Self.alpha, files: ["/a.txt": Data("a".utf8)])
        let destination = FakeRemote(id: Self.beta)

        #expect(throws: CancellationError.self) {
            try RelayCopy.copyFile(
                from: .init(remotePath(Self.alpha, "/a.txt"), on: source),
                to: .init(remotePath(Self.beta, "/a.txt"), on: destination),
                stagingRoot: tree.root,
                // Cancelled the moment the download is done — the gap the relay has that a direct
                // transfer does not.
                progress: { _ in },
                isCancelled: { source.downloads > 0 }
            )
        }
        #expect(destination.uploads == 0)
        #expect(try stagingRootIsEmpty(tree))
    }

    /// The staged name comes from a **remote listing**, which is a stranger's choice — the same
    /// reason this project refuses a CR or LF in an FTP path rather than escaping it. A component
    /// that would climb out of the staging directory is replaced, so the copy lands inside it.
    @Test("a name that would escape the staging directory is replaced, and the copy still lands")
    func hostileNameCannotEscapeStaging() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let payload = Data("payload".utf8)
        let source = FakeRemote(id: Self.alpha, files: ["/..": payload])
        let destination = FakeRemote(id: Self.beta)

        try RelayCopy.copyFile(
            from: .init(remotePath(Self.alpha, "/.."), on: source),
            to: .init(remotePath(Self.beta, "/landed.txt"), on: destination),
            stagingRoot: tree.root,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(destination.contents(of: "/landed.txt") == payload)
        #expect(try stagingRootIsEmpty(tree))
    }

    private func stagingRootIsEmpty(_ tree: TempTree) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty
    }
}

// MARK: - Test backend

/// One remote account, in memory, shaped like `SFTPBackend`/`FTPBackend` where it matters: it moves
/// bytes only when **one end is the local disk**, and refuses every other pair the way both real
/// backends do. A relay that mistakenly handed a two-remote pair to a single backend would meet
/// that refusal rather than pass.
private final class FakeRemote: VFSBackend, @unchecked Sendable {
    let id: VFSBackendID
    var capabilities: VFSCapabilities { [.read, .write, .rename] } // no `.internalCopy`, like SFTP
    /// Whether the upload leg reports as it runs. `false` is `sftp`'s real shape: no meter reaches
    /// a spawned process, so nothing is known until the transfer returns.
    var reportsUploadProgress = true
    /// Set to make the upload leg fail, for the cleanup control.
    var uploadFailure: VFSError?
    private(set) var downloads = 0
    private(set) var uploads = 0
    private let lock = NSLock()
    private var files: [String: Data]

    init(id: VFSBackendID, files: [String: Data] = [:]) {
        self.id = id
        self.files = files
    }

    func contents(of path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[path]
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if isCancelled() { throw CancellationError() }
        if source.backend == id, destination.backend == .local {
            try download(source, to: destination.path, progress: progress)
        } else if source.backend == .local, destination.backend == id {
            try upload(from: source.path, to: destination, progress: progress)
        } else {
            throw VFSError.unsupported(.remoteToRemoteCopy)
        }
    }

    private func download(_ source: VFSPath, to localPath: String, progress: (Int64) -> Void) throws {
        guard let data = contents(of: source.path) else { throw VFSError.notFound(source) }
        try data.write(to: URL(fileURLWithPath: localPath))
        lock.lock(); downloads += 1; lock.unlock()
        report(Int64(data.count), to: progress)
    }

    private func upload(from localPath: String, to destination: VFSPath, progress: (Int64) -> Void) throws {
        if let uploadFailure { throw uploadFailure }
        let data = try Data(contentsOf: URL(fileURLWithPath: localPath))
        lock.lock()
        files[destination.path] = data
        uploads += 1
        lock.unlock()
        if reportsUploadProgress { report(Int64(data.count), to: progress) } else { progress(0) }
    }

    /// Report in four steps, so a test can see the bar move rather than only its total.
    private func report(_ total: Int64, to progress: (Int64) -> Void) {
        let chunk = max(1, total / 4)
        var sent: Int64 = 0
        while sent < total {
            let delta = min(chunk, total - sent)
            sent += delta
            progress(delta)
        }
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard let data = contents(of: path.path) else { throw VFSError.notFound(path) }
        return FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: Int64(data.count),
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }
}
