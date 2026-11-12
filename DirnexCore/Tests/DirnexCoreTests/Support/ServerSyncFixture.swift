import Foundation
import Testing

@testable import DirnexCore

/// A local folder against a folder on ``StampedServer``, with a store, for the M38 Slice 8 suites.
///
/// A sync here is the comparison the Synchronize window makes, the copies its queue would make, and
/// the keep that follows. The copies are made by hand: an upload puts the local bytes on the server
/// with the next stamp, and a download writes the server's bytes here. What is under test is what
/// the record makes of the two sides afterwards, not the transfer.
final class ServerSyncFixture {
    let tree: TempTree
    let store: SyncRecordStore
    let server = StampedServer()
    let pair: SyncRecordPair
    /// Whether the server is the window's left pane, as it is when the panes are swapped.
    let serverOnLeft: Bool
    /// Whether the server sends an entity tag with each file, as S3 and WebDAV do and SFTP does not.
    let tags: Bool
    static let serverRoot = "/srv/R"
    private var clock = 0

    init(
        budget: SyncRecordBudget = .default,
        remembering: Bool = true,
        serverOnLeft: Bool = false,
        tags: Bool = false
    ) throws {
        tree = try TempTree()
        try tree.makeDir("L")
        store = SyncRecordStore(parent: tree.root.appendingPathComponent("support"), budget: budget)
        self.serverOnLeft = serverOnLeft
        self.tags = tags
        let local = tree.vfsPath("L")
        let remote = server.path(Self.serverRoot)
        pair = try #require(SyncRecordPair(
            left: serverOnLeft ? remote : local,
            right: serverOnLeft ? local : remote,
            vaultMountPoints: [],
            allowingServerSide: true
        ))
        if remembering { try store.remember(pair) }
    }

    func cleanup() { tree.cleanup() }

    var localFolder: VFSPath { tree.vfsPath("L") }
    var serverFolder: VFSPath { server.path(Self.serverRoot) }

    func local(_ relative: String) -> URL { URL(fileURLWithPath: tree.path("L/\(relative)")) }
    func serverPath(_ relative: String) -> String { Self.serverRoot + "/" + relative }

    // MARK: - Writes

    /// The next stamp the server's clock gives: a minute on, as an SFTP listing prints it.
    func nextStamp() -> (modified: Date, tag: String?) {
        clock += 1
        return (
            Date(timeIntervalSince1970: 1_800_000_000 + TimeInterval(clock) * 60),
            tags ? "\"t\(clock)\"" : nil
        )
    }

    func writeLocal(_ relative: String, _ text: String) throws {
        let url = local(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    /// Another client's write to the server.
    func writeServer(_ relative: String, _ text: String) {
        let stamp = nextStamp()
        server.put(serverPath(relative), text, modified: stamp.modified, tag: stamp.tag)
    }

    func localText(_ relative: String) throws -> String {
        try String(contentsOf: local(relative), encoding: .utf8)
    }

    // MARK: - A sync

    /// The rows the Synchronize window lists, in its orientation.
    func compare(includingIdentical: Bool = false) throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: serverOnLeft ? serverFolder : localFolder,
            right: serverOnLeft ? localFolder : serverFolder,
            leftBackend: server,
            rightBackend: server,
            comparison: .size,
            includingIdentical: includingIdentical
        )
    }

    /// The direction's default for each row, with `overrides` by relative path.
    func decisions(
        _ rows: [SyncEntry],
        direction: SyncDirection = .bidirectional,
        overrides: [String: SyncAction] = [:]
    ) -> [SyncDecision] {
        rows.map { row in
            SyncDecision(
                entry: row,
                action: overrides[row.relativePath]
                    ?? DirectorySync.defaultAction(for: row.status, direction: direction)
            )
        }
    }

    /// Make the copies `decisions` ask for, as the queue would, leaving out `failing`.
    func copy(_ decisions: [SyncDecision], failing: Set<String> = []) throws {
        for decision in decisions where !failing.contains(decision.entry.relativePath) {
            let toLeft = decision.action == .copyToLeft
            guard toLeft || decision.action == .copyToRight,
                  let source = toLeft ? decision.entry.right : decision.entry.left
            else { continue }
            try copy(decision.entry.relativePath, fromServer: source.path.backend != .local)
        }
    }

    private func copy(_ relative: String, fromServer: Bool) throws {
        if fromServer {
            let prefix = serverPath(relative)
            for key in server.keys(under: prefix) {
                let inner = String(key.dropFirst(Self.serverRoot.count + 1))
                let url = local(inner)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try #require(server.data(key)).write(to: url)
            }
            return
        }
        let url = local(relative)
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        guard isFolder.boolValue else {
            let stamp = nextStamp()
            server.put(
                serverPath(relative),
                data: try Data(contentsOf: url),
                modified: stamp.modified,
                tag: stamp.tag
            )
            return
        }
        let files = FileManager.default.enumerator(atPath: url.path)?.compactMap { $0 as? String } ?? [
        ]
        for inner in files {
            var innerIsFolder: ObjCBool = false
            FileManager.default.fileExists(
                atPath: url.appendingPathComponent(inner).path,
                isDirectory: &innerIsFolder
            )
            if !innerIsFolder.boolValue { try copy(relative + "/" + inner, fromServer: false) }
        }
    }

    /// Compare, copy what the direction asks, and keep: the whole of one sync.
    @discardableResult
    func sync(
        direction: SyncDirection = .bidirectional,
        overrides: [String: SyncAction] = [:],
        failing: Set<String> = [],
        date: Date = Date(timeIntervalSince1970: 1000)
    ) throws -> SyncKeepReport {
        let decisions = try decisions(compare(), direction: direction, overrides: overrides)
        try copy(decisions, failing: failing)
        return try keep(after: decisions, date: date)
    }

    func keep(
        after decisions: [SyncDecision],
        date: Date = Date(timeIntervalSince1970: 1000)
    ) throws -> SyncKeepReport {
        try store.keep(after: decisions, for: pair, using: server, date: date)
    }

    // MARK: - Reading the record

    var record: SyncRecord {
        get throws { try #require(store.record(for: pair)) }
    }

    func kept(_ relative: String) throws -> String? {
        guard let file = try record.keptFile(for: relative) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// What the record says about the window's row for `relative`, identical rows included: a
    /// `.size` comparison lists a same-size edit as identical.
    func change(_ relative: String) throws -> SyncChange? {
        try record.changes(of: compare(includingIdentical: true))[relative]
    }

    /// The server's row for `relative`, as a listing gives it now.
    func serverEntry(_ relative: String) throws -> FileEntry {
        try server.stat(at: server.path(serverPath(relative)))
    }

    func expectStoreMatchesRecord(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let directory = store.directory(of: pair)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let named = try record.versions.values.map(\.file.uuidString).sorted()
        #expect(
            names.filter { $0 != "record.json" }.sorted() == named,
            sourceLocation: sourceLocation
        )
    }
}

extension StampedServer {
    /// Every file at or under `prefix`.
    func keys(under prefix: String) -> [String] {
        allPaths.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
    }
}
