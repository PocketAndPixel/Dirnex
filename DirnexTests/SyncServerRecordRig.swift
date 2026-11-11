import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A server for the Synchronize window's record with a server side (PLAN.md §M38 Slice 9): local
/// paths go to the real `LocalBackend`, and paths on ``serverID`` to files held here, whose stamps
/// move a minute at a time as an SFTP listing prints them. It counts every read of a server file's
/// bytes, since nothing but Merge… may read one.
final class MemorySyncServer: VFSBackend, @unchecked Sendable {
    static let serverID = VFSBackendID.sftp(SFTPLocation(host: "server.test", username: "probe"))

    private struct File {
        var data: Data
        var modified: Date
    }

    private let lock = NSLock()
    private var files: [String: File] = [:]
    private var clock = 0
    private var reads = 0
    let local = LocalBackend()

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { local.capabilities }
    var byteReads: Int { lock.withLock { reads } }

    func path(_ path: String) -> VFSPath { VFSPath(backend: Self.serverID, path: path) }

    /// Write a file on the server with the next minute's stamp.
    func put(_ path: String, data: Data) {
        lock.withLock {
            clock += 1
            files[path] = File(
                data: data,
                modified: Date(timeIntervalSince1970: 1_800_000_000 + Double(clock) * 60)
            )
        }
    }

    func put(_ path: String, _ text: String) { put(path, data: Data(text.utf8)) }

    func text(_ path: String) -> String? {
        lock.withLock { files[path] }.flatMap { String(data: $0.data, encoding: .utf8) }
    }

    func capabilities(for path: VFSPath) -> VFSCapabilities {
        path.backend == .local ? local.capabilities(for: path) : [.read, .write]
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard path.backend == Self.serverID else { return try local.stat(at: path) }
        guard let file = lock.withLock({ files[path.path] }) else { throw VFSError.notFound(path) }
        return entry(path.path, file)
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        guard path.backend == Self.serverID else { return try local.listDirectory(at: path) }
        let prefix = path.path + "/"
        return lock.withLock { files }.compactMap { key, file in
            guard key.hasPrefix(prefix), !key.dropFirst(prefix.count).contains("/") else { return nil }
            return entry(key, file)
        }
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if source.backend == .local {
            put(destination.path, data: try Data(contentsOf: URL(fileURLWithPath: source.path)))
            return
        }
        lock.withLock { reads += 1 }
        guard let file = lock.withLock({ files[source.path] }) else { throw VFSError.notFound(source) }
        try file.data.write(to: URL(fileURLWithPath: destination.path))
    }

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
            inode: 0
        )
    }
}

/// A local folder against a folder on ``MemorySyncServer``, a store in a temporary folder, and the
/// Synchronize window over them (PLAN.md §M38 Slice 9). The store is the rig's own.
@MainActor
final class SyncServerRecordRig {
    static let serverRoot = "/srv/notes"

    let root: URL
    let server = MemorySyncServer()
    let store: SyncRecordStore
    let records: SyncRecordAccess
    /// Whether the server is the window's left pane.
    let serverOnLeft: Bool
    var local: URL { root.appendingPathComponent("local") }
    var localDir: VFSPath { .local(local.path) }
    var serverDir: VFSPath { server.path(Self.serverRoot) }
    var leftDir: VFSPath { serverOnLeft ? serverDir : localDir }
    var rightDir: VFSPath { serverOnLeft ? localDir : serverDir }

    init(serverOnLeft: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sync-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("local"),
            withIntermediateDirectories: true
        )
        let store = SyncRecordStore(parent: root.appendingPathComponent("support"))
        self.store = store
        self.serverOnLeft = serverOnLeft
        let localDir = VFSPath.local(root.appendingPathComponent("local").path)
        let serverDir = server.path(Self.serverRoot)
        records = try #require(SyncRecordAccess(
            left: serverOnLeft ? serverDir : localDir,
            right: serverOnLeft ? localDir : serverDir,
            store: store,
            vaultMountPoints: []
        ))
        try store.remember(records.pair)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeLocal(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: local.appendingPathComponent(name))
    }

    func readLocal(_ name: String) -> String {
        (try? String(contentsOf: local.appendingPathComponent(name), encoding: .utf8)) ?? "<none>"
    }

    func serverPath(_ name: String) -> String { Self.serverRoot + "/" + name }

    /// The rows the window lists, in its orientation.
    func rows() throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: leftDir,
            right: rightDir,
            leftBackend: server,
            rightBackend: server,
            comparison: .size,
            includingIdentical: true
        )
    }

    /// A sync that uploads `name`, as the queue would, and the decisions it ran.
    func upload(_ name: String) throws -> [SyncDecision] {
        let decisions = try rows().filter { $0.relativePath == name }.map {
            SyncDecision(entry: $0, action: serverOnLeft ? .copyToLeft : .copyToRight)
        }
        server.put(serverPath(name), data: try Data(contentsOf: local.appendingPathComponent(name)))
        return decisions
    }

    /// One file uploaded by a sync and kept, then changed differently on each side.
    func changeOnBothSides(_ name: String = "a.txt") throws {
        try writeLocal(name, "one\ntwo\nthree\n")
        _ = try store.keep(after: upload(name), for: records.pair, using: server)
        try writeLocal(name, "ONE\ntwo\nthree\n")
        server.put(serverPath(name), "one\ntwo\nTHREE!\n")
    }

    func keptText(_ name: String) -> String? {
        guard let file = store.record(for: records.pair)?.keptFile(for: name) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    var kept: [String: SyncRecord.Version] {
        store.record(for: records.pair)?.versions ?? [:]
    }

    /// A window over the two folders, scanned and with the record read for its rows.
    func sheet() async throws -> SyncDirectoriesController {
        let controller = SyncDirectoriesController(
            leftDir: leftDir,
            rightDir: rightDir,
            backend: server,
            comparisons: SyncComparison.available(between: leftDir.backend, and: rightDir.backend),
            directions: SyncRecordRig.allDirections,
            records: records
        )
        controller.loadViewIfNeeded()
        try await settleUntil(within: .seconds(60)) { !controller.isScanning && !controller.isReadingChanges }
        return controller
    }

    /// The hosts handed to panes, kept here since a pane holds its host weakly.
    private var hosts: [StubPanelHost] = []

    /// A pane over the same backend, with a host, for the record's work after a sync and a merge's.
    func pane() -> PanelViewController {
        let pane = PanelViewController(
            backend: server,
            restoration: nil,
            defaultPath: localDir,
            restorationKey: nil
        )
        let host = StubPanelHost()
        hosts.append(host)
        pane.host = host
        return pane
    }
}
