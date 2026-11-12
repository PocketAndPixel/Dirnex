import Foundation
import Testing

@testable import DirnexCore

/// Two real folders and a store, for the sync record's suites: what is under test is clones,
/// removals and reads, which a fake cannot stand in for.
struct SyncRecordFixture {
    let tree: TempTree
    let store: SyncRecordStore
    let pair: SyncRecordPair
    let backend = LocalBackend()

    init(budget: SyncRecordBudget = .default, remembering: Bool = true) throws {
        tree = try TempTree()
        try tree.makeDir("L")
        try tree.makeDir("R")
        store = SyncRecordStore(parent: tree.root, budget: budget)
        pair = try #require(SyncRecordPair(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            vaultMountPoints: []
        ))
        if remembering { try store.remember(pair) }
    }

    func cleanup() { tree.cleanup() }

    func left(_ relative: String) -> URL { URL(fileURLWithPath: tree.path("L/\(relative)")) }
    func right(_ relative: String) -> URL { URL(fileURLWithPath: tree.path("R/\(relative)")) }

    func writeBoth(_ relative: String, _ text: String) throws {
        try writeLeft(relative, text)
        try writeRight(relative, text)
    }

    func writeLeft(_ relative: String, _ text: String) throws {
        try tree.writeFile("L/\(relative)", contents: text)
    }

    func writeRight(_ relative: String, _ text: String) throws {
        try tree.writeFile("R/\(relative)", contents: text)
    }

    @discardableResult
    func keep(
        date: Date = Date(timeIntervalSince1970: 1000),
        vaultMountPoints: [String] = []
    ) throws -> SyncKeepReport {
        try store.keep(for: pair, using: backend, vaultMountPoints: vaultMountPoints, date: date)
    }

    var record: SyncRecord {
        get throws { try #require(store.record(for: pair)) }
    }

    /// The text of the version kept for a file, or `nil` when none is.
    func kept(_ relative: String) throws -> String? {
        guard let file = try record.keptFile(for: relative) else { return nil }
        return try String(contentsOf: file, encoding: .utf8)
    }

    func change(_ relative: String) throws -> SyncChange {
        try record.change(of: relative, left: left(relative), right: right(relative))
    }

    /// Every name in the pair's folder but the record itself.
    var storedFiles: [String] {
        let directory = store.directory(of: pair)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0 != "record.json" }
    }

    /// The files a record names, against what is in its folder: a stray or a dangling name fails.
    func expectStoreMatchesRecord(sourceLocation: SourceLocation = #_sourceLocation) throws {
        let named = try record.versions.values.map(\.file.uuidString).sorted()
        #expect(storedFiles.sorted() == named, sourceLocation: sourceLocation)
    }
}
