import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌥F5 over a folder on a server, from the staging job's report to the writer (found live
/// 2026-10-24).
///
/// The folder is brought down whole by `MaterializeRunner`, and the cache deliberately does not
/// adopt a tree (`RemoteFileCache.adopt`). From 2026-08-30 to 2026-10-24 the funnel then looked the
/// folder up in that cache, found nothing, and reported *"Some of the selected items couldn't be
/// prepared"* over a folder that had arrived, leaving it in the temp root. The core's runner was
/// tested and the sheet was tested; the hand-off between them was not, and it is what these pin.
@MainActor
@Suite("A staged folder reaches the pack", .serialized)
struct PackStagedFolderTests {
    @Test("a staged folder is handed over from the job's report")
    func stagedFolderIsHandedOver() async throws {
        let hosted = windowedPane()
        let folder = Handoff.remote("/srv/photos", kind: .directory)
        let tree = try Self.stagedTree(named: "photos")
        hosted.host.materializeReport = Self.report(staging: [(folder, tree)])
        let handed = Handed()

        hosted.pane.materialize(
            [folder],
            for: .pack,
            includingPlaceholders: true,
            failureMessage: neverAsked
        ) { handed.take($0) }
        try await Self.download(in: hosted.window)
        _ = await settle { handed.times > 0 }

        #expect(handed.urls == [tree])
        #expect(hosted.host.materializedEntries.map { $0.map(\.path) } == [[folder.path]])
    }

    /// A folder beside a file that did not arrive is not packed, and since no job will run to sweep
    /// it, the funnel sweeps it: otherwise it sits in the temp root until the next launch.
    @Test("a set that comes up short sweeps the folder it staged")
    func shortSetSweepsTheFolder() async throws {
        let hosted = windowedPane()
        let folder = Handoff.remote("/srv/photos", kind: .directory)
        let lost = Handoff.remote("/srv/notes.txt")
        let tree = try Self.stagedTree(named: "photos")
        hosted.host.materializeReport = Self.report(staging: [(folder, tree)], failing: [lost])
        let handed = Handed()
        var wordedFailure = false

        hosted.pane.materialize([folder, lost], for: .pack, includingPlaceholders: true) {
            wordedFailure = true
            return "couldn’t"
        } then: { handed.take($0) }
        try await Self.download(in: hosted.window)
        _ = await settle { wordedFailure }

        #expect(handed.times == 0)
        #expect(wordedFailure)
        #expect(!FileManager.default.fileExists(atPath: tree.deletingLastPathComponent().path))
    }

    /// The control on the sweep's reach: only a directory under the fetch root is one this app
    /// staged, so a local folder named in the same call is left exactly where it is.
    @Test("the sweep leaves a folder outside the fetch root alone")
    func sweepStaysInsideTheRoot() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-not-staged-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let staged = try Self.stagedTree(named: "photos")

        RemoteFileCache.sweepStagedTrees([outside, staged])

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    // MARK: - Fixtures

    /// A folder staged the way `MaterializeRunner` stages one: in a holder of its own under the
    /// fetch root, keeping its real name, with a file inside.
    private static func stagedTree(named name: String) throws -> URL {
        let tree = RemoteFileCache.temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: tree.appendingPathComponent("one.jpg"))
        return tree
    }

    private static func report(
        staging folders: [(FileEntry, URL)],
        failing failures: [FileEntry] = []
    ) -> OperationReport {
        OperationReport(
            completedItems: folders.count,
            completedBytes: 5,
            skipped: [],
            failures: failures.map {
                OperationItemFailure(path: $0.path, error: .notFound($0.path))
            },
            wasCancelled: false,
            materialized: folders.map {
                MaterializedFile(
                    source: $0.0.path,
                    localPath: $0.1.path,
                    revision: RemoteFileRevision($0.0),
                    isDirectory: true
                )
            }
        )
    }

    /// A folder's size is unknown in advance, so the set is confirmed first: answer Download.
    private static func download(in window: NSWindow) async throws {
        _ = await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the confirmation never appeared")
        try #require(TrashlessProbe.defaultButton(in: sheet)).performClick(nil)
    }
}
