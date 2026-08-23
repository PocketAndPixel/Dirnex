import Foundation
import Testing

@testable import DirnexCore

/// Who tells a backend how big the file is (docs/HISTORY.md ▸ After M19).
///
/// The hint is what decides whether a remote download is split over several connections, and it is
/// deliberately never asked for — a probe would be a full handshake on every small file. So the
/// whole feature rests on the callers that *already* hold the number passing it along, and every one
/// of them fails the same silent way if it does not: the same bytes arrive, over one connection,
/// with nothing anywhere to say the fast path was skipped.
@Suite("The size hint reaches the backend")
struct TransferSizeHintTests {
    /// The engine has the size in the entry it is copying — it came out of the listing — so this
    /// costs no request and is the only place an F5 can learn it.
    @Test("CopyEngine hands over the size its listing already measured")
    func copyEngineForwardsTheEntrySize() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        _ = try tree.writeFile("a.txt", contents: "payload")
        let backend = RecordingBackend()
        let destination = VFSPath(backend: RecordingBackend.remoteID, path: "/dest")

        let report = CopyEngine.run(
            FileOperation(
                kind: .copy,
                sources: [try backend.stat(at: .local(tree.path("a.txt")))],
                destinationDirectory: destination
            ),
            using: backend
        )

        #expect(report.succeeded)
        #expect(backend.hints == [Int64("payload".utf8.count)])
    }

    /// A relay's **download** leg is an ordinary download and gets the hint; its **upload** leg
    /// reads the staged file's own size, which cannot be stale, so it needs nothing. Two legs, one
    /// answer each — and a relay that handed the hint to both would be telling the upload something
    /// about a different file.
    @Test("RelayCopy hints the download leg and not the upload leg")
    func relayHintsTheDownloadLegOnly() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let source = RecordingBackend(id: RecordingBackend.remoteID, files: ["/pub/a.bin": 4096])
        let destination = RecordingBackend(id: VFSBackendID("test-far"))

        try RelayCopy.copyFile(
            from: .init(VFSPath(backend: RecordingBackend.remoteID, path: "/pub/a.bin"), on: source),
            to: .init(VFSPath(backend: destination.id, path: "/in/a.bin"), on: destination),
            stagingRoot: tree.root,
            expectedSize: 4096,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(source.hints == [4096])
        #expect(destination.hints == [nil])
    }

    /// The narrowness control: with nothing to say, a caller says nothing rather than guessing — and
    /// a backend that is handed `nil` behaves exactly as it did before any of this existed.
    @Test("a relay with no size to offer hands over none")
    func relayWithoutASizeHintsNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let source = RecordingBackend(id: RecordingBackend.remoteID, files: ["/pub/a.bin": 128])
        let destination = RecordingBackend(id: VFSBackendID("test-far"))

        try RelayCopy.copyFile(
            from: .init(VFSPath(backend: RecordingBackend.remoteID, path: "/pub/a.bin"), on: source),
            to: .init(VFSPath(backend: destination.id, path: "/in/a.bin"), on: destination),
            stagingRoot: tree.root,
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(source.hints == [nil])
        #expect(destination.hints == [nil])
    }
}

/// A backend that writes down the hint it was given and then copies the bytes.
///
/// It implements **both** spellings, which is the point: a caller that reached the older one would
/// leave `hints` empty rather than failing, so the record has to be able to tell "no hint" from
/// "the old call" — and it does, because only the new spelling appends at all.
private final class RecordingBackend: VFSBackend, @unchecked Sendable {
    static let remoteID = VFSBackendID("test-recording")

    let id: VFSBackendID
    var capabilities: VFSCapabilities { [.read, .write, .rename] } // no `.clone`: never a fast path
    private let lock = NSLock()
    private var files: [String: Int]
    private var recorded: [Int64?] = []

    init(id: VFSBackendID = .local, files: [String: Int] = [:]) {
        self.id = id
        self.files = files
    }

    /// Every hint the new spelling was handed, in call order. An entry of `nil` is a caller that
    /// used it and had nothing to offer; an *absent* entry is a caller that never used it.
    var hints: [Int64?] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        try copyFile(
            at: source,
            to: destination,
            expectedSize: nil,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        expectedSize: Int64?,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        lock.lock(); recorded.append(expectedSize); lock.unlock()
        let data = try bytes(at: source)
        if destination.backend == .local {
            try data.write(to: URL(fileURLWithPath: destination.path))
        } else {
            lock.lock(); files[destination.path] = data.count; lock.unlock()
        }
        progress(Int64(data.count))
    }

    private func bytes(at path: VFSPath) throws -> Data {
        if path.backend == .local {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path.path)) else {
                throw VFSError.notFound(path)
            }
            return data
        }
        lock.lock()
        let size = files[path.path]
        lock.unlock()
        guard let size else { throw VFSError.notFound(path) }
        return Data(repeating: 7, count: size)
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        let size: Int
        if path.backend == .local {
            size = try bytes(at: path).count
        } else {
            lock.lock()
            let stored = files[path.path]
            lock.unlock()
            guard let stored else { throw VFSError.notFound(path) }
            size = stored
        }
        return FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: Int64(size),
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil
        )
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func createDirectory(at path: VFSPath) throws {}
}
