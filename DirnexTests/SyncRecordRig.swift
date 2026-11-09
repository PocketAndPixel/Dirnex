import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Two real folders, a store in a temporary folder and a Synchronize window over them (PLAN.md §M37
/// Slice 8). The store is the rig's own: a test must never reach the developer's.
@MainActor
final class SyncRecordRig {
    static let allDirections: [SyncDirection] = [.leftToRight, .bidirectional, .rightToLeft]

    let root: URL
    let store: SyncRecordStore
    let records: SyncRecordAccess
    var left: URL { root.appendingPathComponent("left") }
    var right: URL { root.appendingPathComponent("right") }
    var leftDir: VFSPath { .local(left.path) }
    var rightDir: VFSPath { .local(right.path) }

    init(remembering: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-sync-record-\(UUID().uuidString)")
        let left = root.appendingPathComponent("left")
        let right = root.appendingPathComponent("right")
        for folder in [left, right] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let store = SyncRecordStore(parent: root.appendingPathComponent("support"))
        self.store = store
        records = try #require(SyncRecordAccess(
            left: .local(left.path),
            right: .local(right.path),
            store: store,
            vaultMountPoints: []
        ))
        if remembering { try store.remember(records.pair) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeLeft(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: left.appendingPathComponent(name))
    }

    func writeRight(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: right.appendingPathComponent(name))
    }

    func writeBoth(_ name: String, _ text: String) throws {
        try writeLeft(name, text)
        try writeRight(name, text)
    }

    func readLeft(_ name: String) -> String {
        (try? String(contentsOf: left.appendingPathComponent(name), encoding: .utf8)) ?? "<none>"
    }

    func readRight(_ name: String) -> String {
        (try? String(contentsOf: right.appendingPathComponent(name), encoding: .utf8)) ?? "<none>"
    }

    /// Keep what the two folders hold, as a finished sync does.
    func keep() throws {
        _ = try store.keep(for: records.pair, using: LocalBackend())
    }

    /// One file kept, then changed differently on each side.
    func changeOnBothSides(_ name: String = "a.txt") throws {
        try writeBoth(name, "one\ntwo\nthree\n")
        try keep()
        try writeLeft(name, "ONE\ntwo\nthree\n")
        try writeRight(name, "one\ntwo\nTHREE!\n")
        try makeLeftNewer(name)
    }

    /// Put the left file an hour ahead, so the walk ranks it. Two files written a moment apart read
    /// as neither newer, which Both Directions already calls a conflict, and a test of what the
    /// record adds would pass without it.
    func makeLeftNewer(_ name: String) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 3600)],
            ofItemAtPath: left.appendingPathComponent(name).path
        )
    }

    var kept: [String: SyncRecord.Version] {
        store.record(for: records.pair)?.versions ?? [:]
    }

    /// The text of the version kept for a file, or `nil` when none is.
    func keptText(_ name: String) -> String? {
        guard let file = store.record(for: records.pair)?.keptFile(for: name) else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// A window over the folders, scanned and with the record read for its rows.
    func sheet(
        directions: [SyncDirection] = SyncRecordRig.allDirections,
        withRecords: Bool = true
    ) async throws -> SyncDirectoriesController {
        let controller = SyncDirectoriesController(
            leftDir: leftDir,
            rightDir: rightDir,
            backend: LocalBackend(),
            comparisons: SyncComparison.available(between: .local, and: .local),
            directions: directions,
            records: withRecords ? records : nil
        )
        controller.loadViewIfNeeded()
        try await settleUntil(within: .seconds(60)) { !controller.isScanning && !controller.isReadingChanges }
        return controller
    }

    /// A row built by hand, for what no real file can be: a side past 64 MiB.
    static func row(
        _ name: String,
        leftSize: Int64 = 4,
        rightSize: Int64 = 5,
        hasRight: Bool = true
    ) -> SyncDirectoriesController.Row {
        func entry(_ side: String, _ size: Int64) -> FileEntry {
            FileEntry(
                path: .local("/\(side)/\(name)"),
                name: name,
                kind: .file,
                byteSize: size,
                modificationDate: Date(timeIntervalSince1970: 1_000_000),
                creationDate: Date(timeIntervalSince1970: 1_000_000),
                isHidden: false,
                permissions: 0o644,
                inode: 0
            )
        }
        return SyncDirectoriesController.Row(
            entry: SyncEntry(
                relativePath: name,
                name: name,
                left: entry("left", leftSize),
                right: hasRight ? entry("right", rightSize) : nil,
                status: .leftNewer
            ),
            action: .copyToRight,
            included: true
        )
    }
}
