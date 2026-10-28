import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Synchronize window comparing one row again after a compare window saved one of its files
/// (PLAN.md §M33 Slice 4). The row is answered as a fresh scan would answer it, and every other row
/// keeps what the user chose in it.
@Suite("Sync sheet: a row compared again after a save")
@MainActor
struct SyncCompareAgainTests {
    /// Two real folders holding two pairs that differ in size.
    final class Fixture {
        let root: URL
        var left: URL { root.appendingPathComponent("left") }
        var right: URL { root.appendingPathComponent("right") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex-sync-again-\(UUID().uuidString)")
            for folder in [left, right] {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
            }
            try Data("the edited body\n".utf8).write(to: left.appendingPathComponent("a.txt"))
            try Data("old\n".utf8).write(to: right.appendingPathComponent("a.txt"))
            try Data("one\n".utf8).write(to: left.appendingPathComponent("b.txt"))
            try Data("other\n".utf8).write(to: right.appendingPathComponent("b.txt"))
        }

        /// Make the right `a.txt` what a save from the compare window leaves: the left's bytes, and
        /// its modification date, so a size-and-date comparison calls them the same.
        func saveRightToMatchLeft() throws {
            let source = left.appendingPathComponent("a.txt")
            let saved = right.appendingPathComponent("a.txt")
            try Data(contentsOf: source).write(to: saved)
            let date = try FileManager.default.attributesOfItem(atPath: source.path)[
                .modificationDate
            ]
            try FileManager.default.setAttributes(
                [.modificationDate: date as Any],
                ofItemAtPath: saved.path
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func sheet(_ fixture: Fixture) -> SyncDirectoriesController {
        let left = VFSPath.local(fixture.left.path)
        let right = VFSPath.local(fixture.right.path)
        let controller = SyncDirectoriesController(
            leftDir: left,
            rightDir: right,
            backend: LocalBackend(),
            comparisons: SyncComparison.available(between: left.backend, and: right.backend),
            directions: [.leftToRight]
        )
        controller.loadViewIfNeeded()
        return controller
    }

    @Test("a saved file whose row now agrees leaves the list, and the other row keeps its tick")
    func agreeingRowLeaves() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sheet = Self.sheet(fixture)
        defer { sheet.stopObservingCompareSaves() }
        try await settleUntil { !sheet.isScanning }
        #expect(sheet.rows.map(\.entry.relativePath) == ["a.txt", "b.txt"])
        sheet.rows[1].included = false

        try fixture.saveRightToMatchLeft()
        CompareWindowController.announceSave(
            of: .local(fixture.right.appendingPathComponent("a.txt").path)
        )
        try await settleUntil { sheet.rows.count == 1 }

        #expect(sheet.rows.map(\.entry.relativePath) == ["b.txt"])
        #expect(sheet.rows.first?.included == false, "the other row keeps what the user chose")
        #expect(sheet.scanned.first { $0.relativePath == "a.txt" }?.status == .identical)
    }

    @Test("a save of a file no row shows changes nothing")
    func otherFileChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sheet = Self.sheet(fixture)
        defer { sheet.stopObservingCompareSaves() }
        try await settleUntil { !sheet.isScanning }

        try fixture.saveRightToMatchLeft()
        CompareWindowController.announceSave(
            of: .local(fixture.root.appendingPathComponent("elsewhere.txt").path)
        )
        // Then the row's own file, so the wait ends on something that does happen.
        CompareWindowController.announceSave(
            of: .local(fixture.left.appendingPathComponent("b.txt").path)
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(sheet.rows.map(\.entry.relativePath) == ["a.txt", "b.txt"])
    }

    // MARK: - Putting the answer in the list

    private static func entry(_ name: String, _ status: SyncStatus) -> SyncEntry {
        SyncEntry(relativePath: name, name: name, left: nil, right: nil, status: status)
    }

    private static func row(_ name: String, _ status: SyncStatus, action: SyncAction, included: Bool)
        -> SyncDirectoriesController.Row {
        SyncDirectoriesController.Row(entry: entry(name, status), action: action, included: included)
    }

    @Test("an answer that agrees takes the row out")
    func identicalLeaves() {
        let rows = [Self.row("a", .leftNewer, action: .copyToRight, included: true)]
        let after = SyncDirectoriesController.rows(
            rows, replacing: Self.entry("a", .identical), direction: .leftToRight
        )
        #expect(after.isEmpty)
    }

    @Test("an unmoved status keeps the action and the tick the user gave the row")
    func unmovedStatusKeepsChoices() {
        let rows = [Self.row("a", .leftNewer, action: .copyToLeft, included: false)]
        let after = SyncDirectoriesController.rows(
            rows, replacing: Self.entry("a", .leftNewer), direction: .leftToRight
        )
        #expect(after.first?.action == .copyToLeft)
        #expect(after.first?.included == false)
    }

    @Test("a moved status takes the direction's default, since the row means something else now")
    func movedStatusTakesTheDefault() {
        let rows = [Self.row("a", .leftNewer, action: .copyToLeft, included: false)]
        let after = SyncDirectoriesController.rows(
            rows, replacing: Self.entry("a", .rightNewer), direction: .leftToRight
        )
        #expect(after.first?.entry.status == .rightNewer)
        #expect(
            after.first?.action == DirectorySync.defaultAction(
                for: .rightNewer,
                direction: .leftToRight
            )
        )
        #expect(after.first?.included == true)
    }

    @Test("a row that differs again after agreeing comes back in its place by path")
    func returningRowIsInsertedInOrder() {
        let rows = [
            Self.row("a", .leftNewer, action: .copyToRight, included: true),
            Self.row("c", .leftNewer, action: .copyToRight, included: true)
        ]
        let after = SyncDirectoriesController.rows(
            rows, replacing: Self.entry("b", .differ), direction: .leftToRight
        )
        #expect(after.map(\.entry.relativePath) == ["a", "b", "c"])
    }
}
