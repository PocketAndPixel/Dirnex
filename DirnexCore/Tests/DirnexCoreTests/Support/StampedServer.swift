import Foundation

@testable import DirnexCore

/// A backend for a sync between this disk and a server, for the M38 Slice 8 suites: local paths go
/// to the real `LocalBackend`, and paths on ``serverID`` to an in-memory server whose stamps a test
/// sets by hand, as a real listing would print them.
///
/// The server's stamps are the whole subject. A record with a server side is read by its size, date
/// and tag and never by its bytes, so the server here counts every listing and every read of its
/// bytes, and a test that claims nothing is downloaded reads ``byteReads``.
final class StampedServer: VFSBackend, @unchecked Sendable {
    static let serverID = VFSBackendID.sftp(SFTPLocation(host: "server.test", username: "probe"))

    /// One file on the server: its bytes, and the stamp a listing prints for it.
    struct File {
        var data: Data
        var modified: Date
        var tag: String?
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var listingCount = 0
    private var byteReadCount = 0
    /// When set, the subtree shortcut answers, with each date moved by this much, as SFTP's exec
    /// channel and its listing print dates their own ways.
    var subtreeDateShift: TimeInterval?
    let local = LocalBackend()

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { local.capabilities }

    /// Directory listings asked of the server, a subtree answer counting as one.
    var listings: Int { lock.withLock { listingCount } }
    /// Reads of the server's bytes.
    var byteReads: Int { lock.withLock { byteReadCount } }

    func path(_ path: String) -> VFSPath { VFSPath(backend: Self.serverID, path: path) }

    /// Put a file on the server, as another client's write or a sync's upload leaves it.
    func put(_ path: String, _ text: String, modified: Date, tag: String? = nil) {
        put(path, data: Data(text.utf8), modified: modified, tag: tag)
    }

    func put(_ path: String, data: Data, modified: Date, tag: String? = nil) {
        lock.withLock { files[path] = File(data: data, modified: modified, tag: tag) }
    }

    /// The bytes at `path`, read by a test rather than through the backend, so not counted.
    func data(_ path: String) -> Data? { lock.withLock { files[path]?.data } }

    var allPaths: [String] { lock.withLock { Array(files.keys) } }

    /// Change a file's stamp and nothing else, as a `touch` does.
    func restamp(_ path: String, modified: Date, tag: String? = nil) {
        lock.withLock {
            files[path]?.modified = modified
            files[path]?.tag = tag
        }
    }

    func remove(_ path: String) { _ = lock.withLock { files.removeValue(forKey: path) } }

    func text(_ path: String) -> String? {
        lock.withLock { files[path] }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    // MARK: - VFSBackend

    func capabilities(for path: VFSPath) -> VFSCapabilities {
        path.backend == .local ? local.capabilities(for: path) : [.read, .write]
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard path.backend == Self.serverID else { return try local.stat(at: path) }
        if let file = lock.withLock({ files[path.path] }) { return entry(path.path, file) }
        guard !children(of: path.path).isEmpty else { throw VFSError.notFound(path) }
        return folder(path.path)
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        guard path.backend == Self.serverID else { return try local.listDirectory(at: path) }
        lock.withLock { listingCount += 1 }
        return listing(of: path.path)
    }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        guard path.backend == Self.serverID, let shift = subtreeDateShift else { return nil }
        lock.withLock { listingCount += 1 }
        let prefix = path.path == "/" ? "/" : path.path + "/"
        var entries: [FileEntry] = []
        var folders: Set<String> = []
        for (key, file) in lock.withLock({ files }) where key.hasPrefix(prefix) {
            var shifted = file
            shifted.modified = file.modified.addingTimeInterval(shift)
            entries.append(entry(key, shifted))
            var parent = VFSPath.local(key).parent?.path
            while let folderPath = parent, folderPath.hasPrefix(prefix) {
                folders.insert(folderPath)
                parent = VFSPath.local(folderPath).parent?.path
            }
        }
        entries += folders.map(folder)
        return VFSSubtreeListing(entries: entries, isComplete: true)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard source.backend == Self.serverID else {
            throw VFSError.notFound(destination)
        }
        lock.withLock { byteReadCount += 1 }
        guard let file = lock.withLock({ files[source.path] }) else { throw VFSError.notFound(source) }
        try file.data.write(to: URL(fileURLWithPath: destination.path))
    }

    // MARK: - A flat keyspace read as a tree

    private func entry(_ path: String, _ file: File) -> FileEntry {
        let full = self.path(path)
        return FileEntry(
            path: full,
            name: full.lastComponent,
            kind: .file,
            byteSize: Int64(file.data.count),
            modificationDate: file.modified,
            creationDate: file.modified,
            isHidden: false,
            permissions: 0o644,
            inode: 0,
            entityTag: file.tag
        )
    }

    private func folder(_ path: String) -> FileEntry {
        let full = self.path(path)
        return FileEntry(
            path: full,
            name: full.lastComponent,
            kind: .directory,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    private func listing(of directory: String) -> [FileEntry] {
        let prefix = directory == "/" ? "/" : directory + "/"
        let snapshot = lock.withLock { files }
        return children(of: directory).map { name, isDirectory in
            isDirectory ? folder(prefix + name) : entry(prefix + name, snapshot[prefix + name]!)
        }
    }

    private func children(of directory: String) -> [(name: String, isDirectory: Bool)] {
        let prefix = directory == "/" ? "/" : directory + "/"
        var seen: [String: Bool] = [:]
        for key in lock.withLock({ Array(files.keys) }) where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard !rest.isEmpty else { continue }
            let head = rest.firstIndex(of: "/").map { String(rest[rest.startIndex..<$0]) }
            seen[head ?? String(rest)] = head != nil || (seen[String(rest)] ?? false)
        }
        return seen.map { ($0.key, $0.value) }
    }
}
