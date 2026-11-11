import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A sync's record with a side on a real SFTP server (PLAN.md §M38 Slices 8 and 9): the comparison,
/// the copies, the keep, a change on both sides, and a merge saved into both, through the real
/// transport. What only a real server can say is whether a stamp kept after the sync reads the same
/// on the next look, since `sftp`'s listing and the exec channel's `find` print a date their own
/// ways and a listing drops the seconds. Gated on the config file, so CI skips it.
@Suite("Sync record over SFTP ▸ live", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SyncServerRecordLiveTests {
    @Test(
        "a sync's record over a real server: kept from the copies, read by stamps, merged and kept again"
    )
    func roundTrip() async throws {
        try await offCooperativePool {
            let pair = try LiveSyncPair()
            defer { pair.cleanup() }
            let store = pair.store

            // The first sync: one file and a folder, uploaded as the queue would.
            try pair.write("a.txt", "one\ntwo\nthree\nfour\nfive\n")
            try pair.write("d/b.txt", "bee\n")
            let decisions = try pair.rows().map {
                SyncDecision(
                    entry: $0,
                    action: DirectorySync.defaultAction(for: $0.status, direction: .bidirectional)
                )
            }
            #expect(decisions.map(\.action) == [.copyToRight, .copyToRight])
            try pair.copyUp("a.txt")
            try pair.account.createDirectory(at: pair.server.appending("d"))
            try pair.copyUp("d/b.txt")
            let report = try store.keep(
                after: decisions,
                for: pair.records.pair,
                using: pair.composite
            )
            #expect(report == SyncKeepReport(kept: 2))

            // The next look reads every stamp as it was kept.
            let record = try #require(store.record(for: pair.records.pair))
            #expect(
                try record.changes(of: pair.rows()) == ["a.txt": .unchanged, "d/b.txt": .unchanged]
            )

            // Both sides change. The server's edit changes the length, since a same-size write in the
            // minute of the upload is one a listing cannot see (seen here first: `five` made `FIVE`
            // read as unchanged), which is the gap the milestone accepted.
            try pair.write("a.txt", "ONE\ntwo\nthree\nfour\nfive\n")
            try pair.upload("one\ntwo\nthree\nfour\nFIVE!\n", to: "a.txt")
            let changed = try record.changes(of: pair.rows())
            let base = try #require(changed["a.txt"]?.mergeBase)
            #expect(changed["d/b.txt"] == .unchanged)

            // Merge…: the server's file comes down, the result goes into both, and the server's new
            // row is kept beside it.
            let theirs = try pair.download("a.txt")
            let merge = try TextMerge(
                base: ComparedDocument.read(contentsOf: base),
                yours: ComparedDocument.read(contentsOf: pair.local.appendingPathComponent("a.txt")),
                theirs: ComparedDocument.read(contentsOf: theirs)
            )
            #expect(merge.isResolved)
            let result = merge.result.lines.map { String($0.content) + $0.terminator.text }.joined()
            #expect(result == "ONE\ntwo\nthree\nfour\nFIVE!\n")
            try pair.write("a.txt", result)
            try Data(result.utf8).write(to: theirs)
            try pair.composite.writeBack(
                localPath: theirs.path,
                to: pair.server.appending("a.txt"),
                condition: .unconditional,
                progress: { _ in },
                isCancelled: { false }
            )
            let kept = try store.keep(
                relativePath: "a.txt",
                local: pair.local.appendingPathComponent("a.txt"),
                server: pair.composite.stat(at: pair.server.appending("a.txt")),
                for: pair.records.pair
            )
            #expect(kept == SyncKeepReport(kept: 1))
            let after = try #require(store.record(for: pair.records.pair))
            #expect(try after.changes(of: pair.rows())["a.txt"] == .unchanged)
            let version = try #require(after.keptFile(for: "a.txt"))
            #expect(try String(contentsOf: version, encoding: .utf8) == result)
        }
    }
}

/// A local folder and a folder on the live SFTP server, remembered in a store of their own.
private struct LiveSyncPair {
    let composite = CompositeBackend(local: LocalBackend())
    let account: SFTPBackend
    let scratch: URL
    let local: URL
    let server: VFSPath
    let store: SyncRecordStore
    let records: SyncRecordAccess

    init() throws {
        let config = try #require(SFTPLiveEnvironment.current)
        account = composite.connectSFTP(
            location: config.location,
            authentication: .key(identityFile: config.identityFile)
        )
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sync-live-\(UUID().uuidString)")
        local = scratch.appendingPathComponent("local")
        try FileManager.default.createDirectory(
            at: local.appendingPathComponent("d"),
            withIntermediateDirectories: true
        )
        server = VFSPath(
            backend: .sftp(config.location),
            path: config.remotePath + "/dirnex-sync-live-\(UUID().uuidString)"
        )
        try account.createDirectory(at: server)
        store = SyncRecordStore(parent: scratch.appendingPathComponent("support"))
        records = try #require(SyncRecordAccess(
            left: .local(local.path),
            right: server,
            store: store,
            vaultMountPoints: []
        ))
        try store.remember(records.pair)
    }

    func cleanup() {
        try? account.removeItem(at: server.appending("a.txt"))
        try? account.removeItem(at: server.appending("d").appending("b.txt"))
        try? account.removeItem(at: server.appending("d"))
        try? account.removeItem(at: server)
        try? FileManager.default.removeItem(at: scratch)
    }

    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: local.appendingPathComponent(name))
    }

    /// The local file at `name`, uploaded to the same place on the server.
    func copyUp(_ name: String) throws {
        let destination = name.split(separator: "/").reduce(server) { $0.appending(String($1)) }
        try composite.copyFile(
            at: .local(local.appendingPathComponent(name).path),
            to: destination,
            progress: { _ in },
            isCancelled: { false }
        )
    }

    /// Another client's write to the server.
    func upload(_ text: String, to name: String) throws {
        let staged = scratch.appendingPathComponent("staged-\(UUID().uuidString)")
        try Data(text.utf8).write(to: staged)
        try composite.copyFile(
            at: .local(staged.path),
            to: server.appending(name),
            progress: { _ in },
            isCancelled: { false }
        )
    }

    func download(_ name: String) throws -> URL {
        let copy = scratch.appendingPathComponent("theirs-\(name)")
        try composite.copyFile(
            at: server.appending(name),
            to: .local(copy.path),
            progress: { _ in },
            isCancelled: { false }
        )
        return copy
    }

    /// The rows the Synchronize window lists, identical ones included.
    func rows() throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: .local(local.path),
            right: server,
            leftBackend: composite,
            rightBackend: composite,
            comparison: .size,
            includingIdentical: true
        )
    }
}
