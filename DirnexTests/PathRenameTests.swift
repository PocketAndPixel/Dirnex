import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// F2 with a name typed as a path, through the pane (2026-11-18): the move lands below the folders it
/// made and journals one record; a folder renamed into itself is refused before anything is touched;
/// and a backend that moves only the long way gets a rename job into the new folder.
///
/// The pane has a window, so a refusal lands as a sheet a test can read rather than a modal alert
/// that waits for a person (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("F2 with a path", .serialized)
struct PathRenameTests {
    private struct Rig {
        let pane: PanelViewController
        let host: StubPanelHost
        let window: NSWindow
        let root: URL

        func path(_ relative: String) -> VFSPath {
            .local(root.appendingPathComponent(relative).path)
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
    }

    private static func rig(backend: any VFSBackend = LocalBackend()) throws -> Rig {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-path-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        return Rig(pane: pane, host: host, window: window, root: root)
    }

    private static func dismissSheet(of window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    @Test("a file moves below the folders F2 made, and one record undoes the whole gesture")
    func movesAndJournals() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try Data("pdf".utf8).write(to: rig.root.appendingPathComponent("report.pdf"))

        rig.pane.performRename(
            source: rig.path("report.pdf"),
            oldName: "report.pdf",
            to: "Archive/2025/report.pdf"
        )
        try await settleUntil { !rig.host.recordedUndo.isEmpty }

        #expect(rig.exists("Archive/2025/report.pdf"))
        #expect(!rig.exists("report.pdf"))
        let record = try #require(rig.host.recordedUndo.first)
        #expect(record.label == .rename)
        #expect(record.steps == [
            .restore(from: rig.path("Archive/2025/report.pdf"), to: rig.path("report.pdf")),
            .removeCreatedFolder(rig.path("Archive/2025")),
            .removeCreatedFolder(rig.path("Archive"))
        ])
    }

    @Test("a folder renamed into itself is refused, and nothing is made")
    func refusesIntoItself() async throws {
        let rig = try Self.rig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try FileManager.default.createDirectory(
            at: rig.root.appendingPathComponent("docs"), withIntermediateDirectories: true
        )

        rig.pane.performRename(source: rig.path("docs"), oldName: "docs", to: "docs/inner")
        try await settleUntil { rig.window.attachedSheet != nil }

        #expect(sheetButtonCount(in: rig.window) == 1)
        #expect(sheetText(in: rig.window).contains { $0.contains("docs") })
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: rig.root.appendingPathComponent("docs").path
            )
            .isEmpty
        )
        #expect(rig.host.recordedUndo.isEmpty)
        Self.dismissSheet(of: rig.window)
    }

    /// An S3 prefix answers `EXDEV`. The folder is made and journaled, and the confirmation the queued
    /// rename always raises comes up; the job it would queue goes into the new folder.
    @Test(
        "a move the backend sends the long way makes the folder and asks before queueing a job into it"
    )
    func deferredMoveAsksForTheJob() async throws {
        let rig = try Self.rig(backend: CrossDeviceBackend())
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try FileManager.default.createDirectory(
            at: rig.root.appendingPathComponent("prefix"), withIntermediateDirectories: true
        )
        try await settleUntil { rig.pane.panel.displayedIndex(ofID: rig.path("prefix")) != nil }

        rig.pane.performRename(source: rig.path("prefix"), oldName: "prefix", to: "Archive/prefix")
        try await settleUntil { rig.window.attachedSheet != nil }

        #expect(rig.exists("Archive"))
        #expect(rig.exists("prefix"))
        #expect(rig.host.recordedUndo.map(\.label) == [.newFolder])
        // Rename and Cancel: the queued rename's confirmation, not a refusal.
        #expect(sheetButtonCount(in: rig.window) == 2)
        Self.dismissSheet(of: rig.window)

        let entry = try #require(
            rig.pane.panel.displayedIndex(ofID: rig.path("prefix")).flatMap { rig.pane.panel.displayedEntry(
                at: $0
            ) }
        )
        let operation = rig.pane.renameOperation(
            for: DeferredRename(source: entry, newName: "prefix", directory: rig.path("Archive"))
        )
        #expect(operation.destinationDirectory == rig.path("Archive"))
    }
}

/// This Mac's disk, with a `moveItem` that answers `EXDEV`, as an S3 prefix rename does.
private struct CrossDeviceBackend: VFSBackend {
    private let local = LocalBackend()
    var id: VFSBackendID { local.id }
    var capabilities: VFSCapabilities { local.capabilities }
    func capabilities(for path: VFSPath) -> VFSCapabilities { local.capabilities(for: path) }
    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try local.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try local.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try local.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try local.removeItem(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        throw VFSError.io(path: source, code: EXDEV)
    }
}
