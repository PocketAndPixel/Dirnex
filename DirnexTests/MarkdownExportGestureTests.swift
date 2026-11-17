import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// File ▸ Export… as a gesture (PLAN.md §M39 ▸ Slice 12): which rows it acts on, what it refuses,
/// the sheet's rules, and what it hands the queue.
///
/// Everything after the sheet's Export button is reached through ``PanelViewController/export(_:_:locateFile:)``
/// with the source already on this disk, since a sheet waits for a person. The download before it is
/// the funnel Share and Pack already use (`PanelViewController+Materialize`).
@MainActor
@Suite("Markdown export: the gesture", .serialized)
struct MarkdownExportGestureTests {
    // MARK: - Which rows

    @Test("a Markdown file under the cursor is exported, a server's by its name")
    func exportableRows() {
        for entry in [
            Handoff.local("/tmp/README.md"),
            Handoff.local("/tmp/Notes.MARKDOWN"),
            Handoff.remote("/srv/guide.mkd")
        ] {
            let (pane, _) = hostedPane(showing: [entry], at: entry.path.parent ?? .local("/tmp"))
            pane.panel.moveCursor(to: 0)
            #expect(pane.exportableCursorFile?.path == entry.path)
        }
    }

    @Test("a folder named like one, and any other file, is not")
    func notExportable() {
        for entry in [Handoff.local("/tmp/docs.md", kind: .directory), Handoff.local("/tmp/a.txt")] {
            let (pane, _) = hostedPane(showing: [entry])
            pane.panel.moveCursor(to: 0)
            #expect(pane.exportableCursorFile == nil)
        }
    }

    @Test("Export is offered only with a pane to export into")
    func needsACounterpart() {
        let (pane, host) = hostedPane(showing: [Handoff.local("/tmp/README.md")])
        pane.panel.moveCursor(to: 0)
        #expect(!pane.canExport)
        let (other, _) = hostedPane(at: .local("/tmp/dest"))
        host.counterpart = other
        #expect(pane.canExport)
    }

    // MARK: - The sheet, or a refusal

    @Test("a writable other pane gets the sheet, a read-only one a refusal")
    func sheetOrRefusal() async throws {
        let destination = VFSPath(backend: Handoff.remoteID, path: "/bucket")
        for readOnly in [false, true] {
            var backend = Handoff.StubBackend()
            if readOnly { backend.readOnlyPaths = [destination] }
            let source = windowedPane(showing: [Handoff.local("/tmp/README.md")], backend: backend)
            let (other, _) = hostedPane(at: destination, backend: backend)
            source.host.counterpart = other
            source.pane.panel.moveCursor(to: 0)

            source.pane.beginExport()
            try await settleUntil { source.window.attachedSheet != nil }

            // The sheet offers Export, Cancel and the format popup; a refusal offers OK.
            #expect((sheetButtonCount(in: source.window) == 1) == readOnly)
            #expect(sheetText(in: source.window).contains("README.html") == !readOnly)
            #expect(source.host.enqueued.isEmpty)
        }
    }

    // MARK: - After the sheet

    @Test(
        "an export is a staged file under its own name, copied into the folder by the queue",
        arguments: MarkdownExport.Format.allCases
    )
    func queuedCopy(format: MarkdownExport.Format) async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# Read me\n\nText.")
        let source = Handoff.entry(.local(url.path))
        let (pane, host) = hostedPane(showing: [source], at: .local(tree.root.path))
        let folder = VFSPath.local(tree.root.appendingPathComponent("out").path)
        let name = MarkdownExport.fileName(forSource: "README.md", as: format)

        await pane.export(url, MarkdownExportRequest(
            source: source, format: format, name: name, folder: folder
        ))

        let operation = try #require(host.enqueued.first)
        #expect(host.enqueued.count == 1)
        #expect(operation.kind == .copy)
        #expect(operation.destinationDirectory == folder)
        let staged = try #require(operation.sources.first)
        #expect(staged.name == name)
        #expect(
            staged.path.path.hasPrefix(MarkdownExportStaging.root.standardizedFileURL.path + "/")
                || staged.path.path.hasPrefix(MarkdownExportStaging.root.path + "/")
        )
        let bytes = try Data(contentsOf: URL(fileURLWithPath: staged.path.path))
        let header = format == .html ? "<!doctype html>" : "%PDF-"
        #expect(bytes.starts(with: Data(header.utf8)))
        MarkdownExportStaging.discard(URL(fileURLWithPath: staged.path.path))
    }

    @Test("a file with no page queues nothing and says why")
    func failureQueuesNothing() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("binary.md")
        try Data([0x00, 0x01, 0x02, 0x00]).write(to: url)
        let source = Handoff.entry(.local(url.path))
        let windowed = windowedPane(showing: [source])

        await windowed.pane.export(url, MarkdownExportRequest(
            source: source, format: .html, name: "binary.html", folder: .local(tree.root.path)
        ))
        try await settleUntil { windowed.window.attachedSheet != nil }

        #expect(windowed.host.enqueued.isEmpty)
        #expect(sheetButtonCount(in: windowed.window) == 1)
    }

    // MARK: - The folder field

    @Test("typed text names a folder on the other pane's backend")
    func typedFolder() {
        let base = VFSPath.local("/Users/someone/Docs")
        #expect(PanelViewController.exportFolder(typed: "", from: base) == base)
        #expect(PanelViewController.exportFolder(typed: "  ", from: base) == base)
        #expect(
            PanelViewController.exportFolder(typed: "out", from: base) == .local(
                "/Users/someone/Docs/out"
            )
        )
        #expect(PanelViewController.exportFolder(typed: "/tmp/x/", from: base) == .local("/tmp/x"))
        #expect(PanelViewController.exportFolder(typed: "~/Desktop", from: base)
            == .local(NSHomeDirectory() + "/Desktop"))
        // `~` is this Mac's home, so on a server it is a name like any other.
        let remote = VFSPath(backend: Handoff.remoteID, path: "/home/user")
        #expect(PanelViewController.exportFolder(typed: "~/x", from: remote)
            == VFSPath(backend: Handoff.remoteID, path: "/home/user/~/x"))
        #expect(PanelViewController.exportFolder(typed: "/", from: remote)
            == VFSPath(backend: Handoff.remoteID, path: "/"))
    }

    @Test("a folder that is not there is said so, and one that is passes")
    func folderProblems() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let backend = LocalBackend()
        #expect(await PanelViewController.folderProblem(.local(tree.root.path), on: backend) == nil)
        let missing = VFSPath.local(tree.root.appendingPathComponent("nope").path)
        #expect(await PanelViewController.folderProblem(missing, on: backend) != nil)
        let file = try tree.write("file.txt", contents: "x")
        #expect(await PanelViewController.folderProblem(.local(file.path), on: backend) != nil)
    }

    // MARK: - The sheet's controls

    @Test("the format is remembered, HTML until a first choice")
    func formatMemory() {
        let defaults = ScratchDefaults.fresh()
        let memory = MarkdownExportFormatMemory(defaults: defaults)
        #expect(memory.format == .html)
        memory.format = .pdf
        #expect(MarkdownExportFormatMemory(defaults: defaults).format == .pdf)
        defaults.set("rtf", forKey: MarkdownExportFormatMemory.key)
        #expect(memory.format == .html)
    }

    @Test("the name follows the format, unless the user named it otherwise")
    func nameFollowsFormat() {
        let accessory = MarkdownExportAccessory.make(
            format: .html,
            name: "README.html",
            folder: "/tmp"
        )
        Self.choose(.pdf, in: accessory)
        #expect(accessory.nameField.stringValue == "README.pdf")
        Self.choose(.html, in: accessory)
        #expect(accessory.nameField.stringValue == "README.html")
        accessory.nameField.stringValue = "notes"
        Self.choose(.pdf, in: accessory)
        #expect(accessory.nameField.stringValue == "notes")
        #expect(accessory.format == .pdf)
    }

    @Test("an error grows the form by its own height, and going grows it back")
    func errorRow() {
        let accessory = MarkdownExportAccessory.make(format: .pdf, name: "a.pdf", folder: "/tmp")
        let height = accessory.view.frame.height
        accessory.showError("Something is wrong with the name.")
        #expect(accessory.view.frame.height > height)
        #expect(!accessory.errorLabel.isHidden)
        accessory.showError(nil)
        #expect(accessory.view.frame.height == height)
        #expect(accessory.errorLabel.isHidden)
    }

    // MARK: - Staging

    @Test("each export is staged alone under its real name, and a discard takes only its own")
    func staging() throws {
        let first = try MarkdownExportStaging.newFile(named: "README.html")
        let second = try MarkdownExportStaging.newFile(named: "README.html")
        #expect(first.lastPathComponent == "README.html")
        #expect(first.deletingLastPathComponent() != second.deletingLastPathComponent())
        try Data("x".utf8).write(to: first)
        MarkdownExportStaging.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
        MarkdownExportStaging.discard(second)

        // Nothing outside the root is removed, whatever is handed over.
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let outside = try tree.write("keep.html", contents: "x")
        MarkdownExportStaging.discard(outside)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    private static func choose(
        _ format: MarkdownExport.Format,
        in accessory: MarkdownExportAccessory
    ) {
        let popup = accessory.formatPopup
        popup.selectItem(at: MarkdownExport.Format.allCases.firstIndex(of: format) ?? 0)
        popup.sendAction(popup.action, to: popup.target)
    }
}
