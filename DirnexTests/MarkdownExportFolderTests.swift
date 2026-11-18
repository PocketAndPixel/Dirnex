import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// File ▸ Export…'s folder field: which folder typed text names, and what the sheet does with it.
///
/// Out of `MarkdownExportGestureTests` since 2026-11-18, when a folder that is not there stopped
/// being refused and started being offered: the first press of Export says so under the form, and a
/// second press while the field still names it makes the folder, after the page is written.
@MainActor
@Suite("Markdown export: the folder field", .serialized)
struct MarkdownExportFolderTests {
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

    @Test(
        "a folder that is there passes, and one that is not is offered, then made on a second press"
    )
    func folderChecks() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let backend = LocalBackend()
        let here = VFSPath.local(tree.root.path)
        let missing = here.appending("out").appending("deeper")

        #expect(await PanelViewController.folderCheck(here, confirmed: nil, on: backend) == .ready)
        guard case let .offerToCreate(sentence) = await PanelViewController.folderCheck(
            missing, confirmed: nil, on: backend
        ) else {
            Issue.record("a missing folder should be offered")
            return
        }
        #expect(sentence.contains(missing.path))
        #expect(
            await PanelViewController.folderCheck(missing, confirmed: missing, on: backend) == .create
        )
        // A press on another missing folder is asked about afresh.
        let other = here.appending("elsewhere")
        guard case .offerToCreate = await PanelViewController.folderCheck(
            other, confirmed: missing, on: backend
        ) else {
            Issue.record("a different folder should be offered again")
            return
        }
        // Checking makes nothing.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty)
    }

    @Test(
        "a file where the folder would be, or on its way, is refused, and so is a read-only parent"
    )
    func folderRefusals() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let backend = LocalBackend()
        let file = try tree.write("notes", contents: "x")

        guard case .refused = await PanelViewController.folderCheck(
            .local(file.path), confirmed: .local(file.path), on: backend
        ) else {
            Issue.record("a file is no folder")
            return
        }
        guard case let .refused(sentence) = await PanelViewController.folderCheck(
            .local(file.path + "/sub"), confirmed: .local(file.path + "/sub"), on: backend
        ) else {
            Issue.record("a file on the way should be refused")
            return
        }
        #expect(sentence.contains("notes"))

        // The stub has nothing to `stat`, so every folder is missing under the root, and the root is
        // read-only: there is nowhere the folder could be made.
        let readOnly = Handoff.StubBackend(readOnlyPaths: [.local("/")])
        guard case .refused = await PanelViewController.folderCheck(
            .local("/new"), confirmed: .local("/new"), on: readOnly
        ) else {
            Issue.record("a read-only parent should be refused")
            return
        }
    }

    /// The second press's answer: the folders are made only once the page is written, journaled as a
    /// New Folder of their own, and the copy goes into them.
    @Test("an export into a folder the user said to make makes it, journals it, and copies into it")
    func exportMakesTheFolder() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# Read me")
        let source = Handoff.entry(.local(url.path))
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local(tree.root.path),
            restorationKey: nil
        )
        let host = StubPanelHost()
        pane.host = host
        let folder = VFSPath.local(tree.root.path).appending("out").appending("deeper")

        await pane.export(url, MarkdownExportRequest(
            source: source, format: .html, name: "README.html", folder: folder, createsFolder: true
        ))

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(host.enqueued.map(\.destinationDirectory) == [folder])
        let record = try #require(host.recordedUndo.first)
        #expect(record.label == .newFolder)
        #expect(record.steps.count == 2)
        for operation in host.enqueued {
            for staged in operation.sources {
                MarkdownExportStaging.discard(URL(fileURLWithPath: staged.path.path))
            }
        }
    }
}
