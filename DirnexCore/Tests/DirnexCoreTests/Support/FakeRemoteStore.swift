import Foundation

@testable import DirnexCore

/// An in-memory stand-in for a server, for the M24 Slice 4 tests: it lists, it serves bytes, and —
/// unlike the download-only double `MaterializeRunnerTests` keeps to itself — it **receives** them,
/// which is the half a checksum manifest written beside a bucket's objects needs.
///
/// Deliberately not a mock of any real transport. What the tests over it assert is what reached a
/// *path*: which names a manifest ended up spelling, and where the file landed. Nothing here knows
/// about `curl`, `sftp` or signatures, and nothing that does is exercised by pretending it is.
final class FakeRemoteStore: VFSBackend, @unchecked Sendable {
    static let backendID = VFSBackendID("test-store://host")

    private let lock = NSLock()
    private var files: [String: String]
    private var refusedUploads: Set<String>

    init(_ files: [String: String], refusingUploadsTo refusedUploads: Set<String> = []) {
        self.files = files
        self.refusedUploads = refusedUploads
    }

    /// What is on the "server" now, including anything uploaded during the test.
    var contents: [String: String] { lock.withLock { files } }

    var id: VFSBackendID { Self.backendID }
    var capabilities: VFSCapabilities { [.read, .write] }

    func path(_ path: String) -> VFSPath { VFSPath(backend: id, path: path) }

    func entry(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        let full = self.path(path)
        return FileEntry(
            path: full,
            name: full.lastComponent,
            kind: kind,
            byteSize: Int64(lock.withLock { files[path] }?.utf8.count ?? 0),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000),
            isHidden: full.lastComponent.hasPrefix("."),
            permissions: 0o644,
            inode: 1
        )
    }

    // MARK: - VFSBackend

    func stat(at path: VFSPath) throws -> FileEntry {
        if lock.withLock({ files[path.path] }) != nil { return entry(path.path) }
        guard !children(of: path.path).isEmpty else { throw VFSError.notFound(path) }
        return entry(path.path, kind: .directory)
    }

    /// The immediate children of `path`, derived from the keys — a flat keyspace read as a tree,
    /// which is what S3 really is and close enough to what the others look like from here.
    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        children(of: path.path).map { name, isDirectory in
            let prefix = path.path == "/" ? "/" : path.path + "/"
            return entry(prefix + name, kind: isDirectory ? .directory : .file)
        }
        .sorted { $0.name < $1.name }
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if source.backend == .local, destination.backend == id {
            guard !refusedUploads.contains(destination.path) else {
                throw VFSError.permissionDenied(destination)
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: source.path))
            let text = String(bytes: data, encoding: .utf8) ?? ""
            lock.withLock { files[destination.path] = text }
            progress(Int64(data.count))
            return
        }
        guard let contents = lock.withLock({ files[source.path] }) else {
            throw VFSError.notFound(source)
        }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: destination.path))
        progress(Int64(contents.utf8.count))
    }

    // MARK: - Deriving a tree from a flat keyspace

    private func children(of directory: String) -> [(name: String, isDirectory: Bool)] {
        let prefix = directory == "/" ? "/" : directory + "/"
        var seen: [String: Bool] = [:]
        for key in lock.withLock({ Array(files.keys) }) where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard !rest.isEmpty else { continue }
            let head = rest.firstIndex(of: "/").map { String(rest[rest.startIndex..<$0]) }
            seen[head ?? String(rest)] = head != nil
        }
        return seen.map { ($0.key, $0.value) }
    }
}
