import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// F5 and F6 into a folder typed into the dialog's field in place of the other pane's (2026-11-19):
/// a folder that is not there is made with the folders on its way and journaled before the job is
/// queued into it, one that is there is used as it is, and the folder the marks are in or one inside
/// a marked folder is refused with the dialog still up.
///
/// `StubPanelHost.typedDestination` stands in for the field: it is checked by the summary's
/// `refusal`, as the dialog checks it, and handed to `start` in place of the summary's folder.
@MainActor
@Suite("F5 into a typed folder", .serialized)
struct TransferDestinationTests {
    /// `<root>/a.txt`, `<root>/sub/b.txt` and `<root>/dest` on disk, a pane at `<root>` and a
    /// counterpart at `dest`. Real files and a real `LocalBackend`, since the folders are made.
    @MainActor
    private struct Fixture {
        let root: URL
        let source: WindowedPane

        var rootPath: VFSPath { .local(root.path) }
        var destination: VFSPath { rootPath.appending("dest") }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex-typed-destination-\(UUID().uuidString)")
            let fileManager = FileManager.default
            for folder in ["sub", "dest"] {
                try fileManager.createDirectory(
                    at: root.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
            try Data("b".utf8).write(to: root.appendingPathComponent("sub/b.txt"))

            let backend = LocalBackend()
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
                defaultPath: .local(root.path),
                restorationKey: nil
            )
            let host = StubPanelHost()
            pane.host = host
            window.contentViewController = pane
            pane.loadViewIfNeeded()
            host.counterpart = PanelViewController(
                backend: backend,
                restoration: nil,
                defaultPath: VFSPath.local(root.path).appending("dest"),
                restorationKey: nil
            )
            source = WindowedPane(pane: pane, host: host, window: window)
        }

        /// Mark `names` in the pane's own listing, read from disk.
        func mark(_ names: [String]) throws {
            let backend = LocalBackend()
            var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
                path: rootPath,
                entries: try backend.listDirectory(at: rootPath)
            )))
            for row in 0..<panel.count {
                if let entry = panel.displayedEntry(at: row), names.contains(entry.name) {
                    panel.toggleMark(at: row)
                }
            }
            source.pane.panel = panel
        }

        func isFolder(_ path: VFSPath) -> Bool {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        /// The pane leaves its window before its folder goes (`TreeTransferTests.Fixture.cleanUp`).
        func cleanUp() {
            source.window.contentViewController = nil
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("a folder that is not there is made with the folders on its way, then copied into")
    func missingFolderIsMade() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.mark(["a.txt"])
        let typed = fixture.destination.appending("new").appending("deeper")
        fixture.source.host.typedDestination = typed

        fixture.source.pane.copyToOtherPane(nil)
        try await settleUntil { fixture.source.host.enqueued.count == 1 }

        let job = fixture.source.host.enqueued[0]
        #expect(job.kind == .copy)
        #expect(job.destinationDirectory == typed)
        #expect(job.sources.map(\.name) == ["a.txt"])
        #expect(fixture.isFolder(typed))
        // Journaled before the job, so ⌘Z takes back the copy first and then the folders.
        let record = try #require(fixture.source.host.recordedUndo.first)
        #expect(fixture.source.host.recordedUndo.count == 1)
        #expect(record.label == .newFolder)
        #expect(fixture.source.host.transferRefusals.isEmpty)
    }

    @Test("a folder that is there is moved into as it is, with nothing made or journaled")
    func existingFolderIsUsed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.mark(["a.txt"])
        let typed = fixture.rootPath.appending("sub")
        fixture.source.host.typedDestination = typed

        fixture.source.pane.moveToOtherPane(nil)
        try await settleUntil { fixture.source.host.enqueued.count == 1 }

        #expect(fixture.source.host.enqueued[0].kind == .move)
        #expect(fixture.source.host.enqueued[0].destinationDirectory == typed)
        #expect(fixture.source.host.recordedUndo.isEmpty)
    }

    /// The control is the same marks with the other pane's own folder, which is not refused.
    @Test(
        "the marks' own folder and a folder inside a marked folder are refused, and nothing is made"
    )
    func refusals() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.mark(["a.txt", "sub"])
        let host = fixture.source.host

        host.typedDestination = fixture.rootPath
        fixture.source.pane.copyToOtherPane(nil)
        let inside = fixture.rootPath.appending("sub").appending("x")
        host.typedDestination = inside
        fixture.source.pane.moveToOtherPane(nil)

        #expect(host.transferRefusals == [
            String(localized: "Can’t copy into the same folder"),
            PanelViewController.intoItselfSentence(.move, "sub")
        ])
        #expect(host.enqueued.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: inside.path))

        host.typedDestination = nil
        fixture.source.pane.copyToOtherPane(nil)
        #expect(host.enqueued.count == 1)
        #expect(host.enqueued[0].destinationDirectory == fixture.destination)
    }

    /// The create's failure is the alert, and the tracker is told nothing is coming, which is what
    /// lets a dialog following the transfer close.
    @Test("a file in the way fails the create, queues nothing and finishes the tracker")
    func fileInTheWay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.mark(["sub"])
        var finished = 0
        fixture.source.host.trackTransfers = {
            TransferTracker(onTrack: { _ in }, onFinish: { finished += 1 })
        }
        fixture.source.host.typedDestination = fixture.rootPath.appending("a.txt").appending("x")

        fixture.source.pane.copyToOtherPane(nil)
        try await settleUntil { finished == 1 }
        try await settleUntil { fixture.source.window.attachedSheet != nil }

        #expect(fixture.source.host.enqueued.isEmpty)
        #expect(fixture.source.host.recordedUndo.isEmpty)
        if let sheet = fixture.source.window.attachedSheet {
            fixture.source.window.endSheet(sheet)
        }
    }
}
