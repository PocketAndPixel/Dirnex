import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// F5 and F6 from a tree whose marks span levels (2026-10-14): flat into the other pane's folder, as
/// drag-and-drop and ⌘V always were, while ⇧F5 and Move Keeping Folders recreate the folders the
/// marks were found in.
///
/// What a test can see is the hand-over, the jobs a gesture queued: `StubPanelHost` records them and
/// runs nothing. The engine's half of going flat, two same-named marks meeting as a conflict rather
/// than overwriting each other, is pinned in the core (`CopyEngineAskTests`).
@MainActor
@Suite("F5 and ⇧F5 from a tree", .serialized)
struct TreeTransferTests {
    /// `<root>/a.txt` and `<root>/sub/b.txt` on disk, a pane at `<root>` in tree mode with `sub`
    /// expanded, and a counterpart pane at `destination`. Real files and a real `LocalBackend`,
    /// because keeping folders creates them before it queues anything.
    @MainActor
    private struct Fixture {
        let root: URL
        let source: WindowedPane
        let destination: VFSPath

        var rootPath: VFSPath { .local(root.path) }
        var aPath: VFSPath { rootPath.appending("a.txt") }
        var subPath: VFSPath { rootPath.appending("sub") }
        var bPath: VFSPath { subPath.appending("b.txt") }

        /// The pane is in its window before the tree goes in: loading the view navigates, and a
        /// tree assigned after that is the one the gesture reads.
        init(destination relative: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex-tree-transfer-\(UUID().uuidString)")
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: root.appendingPathComponent("sub"),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: root.appendingPathComponent("dest"),
                withIntermediateDirectories: true
            )
            try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
            try Data("b".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
            destination = VFSPath.local(root.path).appending(relative)

            let backend = LocalBackend()
            source = Self.windowed(at: .local(root.path), backend: backend)
            let other = PanelViewController(
                backend: backend,
                restoration: nil,
                defaultPath: destination,
                restorationKey: nil
            )
            source.host.counterpart = other
        }

        private static func windowed(at path: VFSPath, backend: LocalBackend) -> WindowedPane {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            RetainedWindows.all.append(window)
            let pane = PanelViewController(
                backend: backend,
                restoration: nil,
                defaultPath: path,
                restorationKey: nil
            )
            let host = StubPanelHost()
            pane.host = host
            window.contentViewController = pane
            pane.loadViewIfNeeded()
            return WindowedPane(pane: pane, host: host, window: window)
        }

        /// Put the tree in and mark `marked`, in the same turn as the gesture that reads it.
        func markInTree(_ marked: Set<VFSPath>) throws {
            let backend = LocalBackend()
            var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
                path: rootPath,
                entries: [try backend.stat(at: subPath), try backend.stat(at: aPath)]
            )))
            panel.enterTreeMode()
            panel.setTreeChildListing(subPath, entries: [try backend.stat(at: bPath)])
            panel.expand(subPath)
            for row in 0..<panel.count {
                if let entry = panel.displayedEntry(at: row), marked.contains(entry.path) {
                    panel.toggleMark(at: row)
                }
            }
            source.pane.panel = panel
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("F5 lands marks from two levels side by side in one job")
    func copyIsFlat() throws {
        let fixture = try Fixture(destination: "dest")
        defer { fixture.cleanUp() }
        try fixture.markInTree([fixture.aPath, fixture.bPath])

        fixture.source.pane.copyToOtherPane(nil)

        let jobs = fixture.source.host.enqueued
        try #require(jobs.count == 1)
        #expect(jobs[0].kind == .copy)
        #expect(jobs[0].destinationDirectory == fixture.destination)
        #expect(Set(jobs[0].sources.map(\.path)) == [fixture.aPath, fixture.bPath])
        // Nothing was made: flat has no folder to recreate.
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appending("sub").path))
    }

    @Test("⇧F5 recreates the folder a mark was found in, and queues one job per level")
    func copyKeepingFoldersRecreatesTheFolder() async throws {
        let fixture = try Fixture(destination: "dest")
        defer { fixture.cleanUp() }
        try fixture.markInTree([fixture.aPath, fixture.bPath])

        fixture.source.pane.copyToOtherPaneKeepingFolders(nil)
        try await settleUntil { fixture.source.host.enqueued.count == 2 }

        let jobs = fixture.source.host.enqueued
        try #require(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.kind == .copy })
        #expect(jobs[0].destinationDirectory == fixture.destination)
        #expect(jobs[0].sources.map(\.path) == [fixture.aPath])
        #expect(jobs[1].destinationDirectory == fixture.destination.appending("sub"))
        #expect(jobs[1].sources.map(\.path) == [fixture.bPath])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: fixture.destination.appending("sub").path,
            isDirectory: &isDirectory
        ))
        #expect(isDirectory.boolValue)
    }

    /// The other pane shows `sub`, which the tree has expanded, so `b.txt` would land on itself.
    /// Moving it there is nothing; the mark beside it still moves.
    @Test("F6 drops a mark that already lives in the destination and moves the rest")
    func moveDropsAMarkAlreadyThere() throws {
        let fixture = try Fixture(destination: "sub")
        defer { fixture.cleanUp() }
        try fixture.markInTree([fixture.aPath, fixture.bPath])

        fixture.source.pane.moveToOtherPane(nil)

        let jobs = fixture.source.host.enqueued
        try #require(jobs.count == 1)
        #expect(jobs[0].kind == .move)
        #expect(jobs[0].destinationDirectory == fixture.subPath)
        #expect(jobs[0].sources.map(\.path) == [fixture.aPath])
    }

    /// With only that mark, nothing is left to transfer, and the gesture says so the way F5 between
    /// two panes on one folder always has: a refusal with one button, and no job.
    @Test("F5 with every mark already in the destination refuses rather than duplicating")
    func copyOfOnlyAMarkAlreadyThereIsRefused() async throws {
        let fixture = try Fixture(destination: "sub")
        defer { fixture.cleanUp() }
        try fixture.markInTree([fixture.bPath])

        fixture.source.pane.copyToOtherPane(nil)
        try await settleUntil { fixture.source.window.attachedSheet != nil }

        #expect(fixture.source.host.enqueued.isEmpty)
        #expect(sheetButtonCount(in: fixture.source.window) == 1)
        if let sheet = fixture.source.window.attachedSheet {
            fixture.source.window.endSheet(sheet)
        }
    }

    /// Keeping folders has no such case: `b.txt` goes to `sub/sub`, one level under the folder it
    /// came from, so nothing lands on itself and nothing is dropped.
    @Test("⇧F5 keeps a mark that plain F5 would drop, under its own folder")
    func copyKeepingFoldersKeepsEveryMark() async throws {
        let fixture = try Fixture(destination: "sub")
        defer { fixture.cleanUp() }
        try fixture.markInTree([fixture.bPath])

        fixture.source.pane.copyToOtherPaneKeepingFolders(nil)
        try await settleUntil { fixture.source.host.enqueued.count == 1 }

        let jobs = fixture.source.host.enqueued
        try #require(jobs.count == 1)
        #expect(jobs[0].destinationDirectory == fixture.subPath.appending("sub"))
        #expect(jobs[0].sources.map(\.path) == [fixture.bPath])
    }
}
