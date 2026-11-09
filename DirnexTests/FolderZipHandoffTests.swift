import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A folder dragged toward an app other than Finder goes as itself, and as a zip of itself while Shift
/// is held (2026-11-08, behind Shift since 2026-11-09).
///
/// Gmail answers "Attachment failed" for a folder dropped from Chrome, while VLC takes the folder and
/// was handed a zip of a whole season when every app but Finder got one. So the drag's handoff offers
/// `<folder>.zip`, made by ⌥F5's own `bsdtar` packer, only while Shift is held over such an app, and
/// Finder is always offered the folder. A drag session cannot be synthesized, so the real board stands
/// in for the session's, and the pointer and the key are injected; a press with the pointer still was
/// measured with a throwaway drag source (`DragShiftWatch`). The zips are real, and a server's folder
/// is really staged, through a backend that mirrors a local directory under a server's id and routes
/// the way the app's `CompositeBackend` does.
@MainActor
@Suite("Folder zip handoff")
struct FolderZipHandoffTests {
    // MARK: - A folder on this disk

    @Test("a folder on this disk drags to every app by its own URL, before Shift")
    func localFolderStartsAsItsOwnURL() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        let row = tree.localEntry
        let routes = pane.dragOutRoutes(for: [row])
        #expect(routes[row.path] == .folderURL)
        let rig = FolderZipRig("local-start")
        #expect(rig.board.writeObjects(PanelPasteboard.dragWriters(
            for: [row], routes: routes, promisedTo: pane
        )))
        let controller = rig.start([row], route: .folderURL, backend: LocalBackend())

        controller.pointerMoved()

        // The board the drag began with, untouched, and nothing made: VLC took this first time.
        #expect(rig.readURL()?.path == tree.folder.path)
        #expect(controller.handoff.transfer == .notStarted)
        #expect(FolderZipListing.left(named: "\(tree.name).zip").isEmpty)
        #expect(rig.statuses.last == RemoteDragStatus.holdShiftAndReenter)
        controller.dragEnded(mayFinish: false)
    }

    @Test("entering another app with Shift hands it a zip of a folder on this disk")
    func localFolderIsZippedWithShift() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("local")
        let controller = rig.start([tree.localEntry], route: .folderURL, backend: LocalBackend())

        rig.shift = true
        controller.pointerMoved()
        let zip = try #require(rig.readURL())

        #expect(zip.lastPathComponent == "\(tree.name).zip")
        #expect(try FolderZipListing.listing(zip) == tree.zipListing)
        // Under the temp root, which is cleared at the next launch, never beside the folder.
        #expect(zip.path.hasPrefix(RemoteFileCache.temporaryRoot.path))
        #expect(!FileManager.default.fileExists(
            atPath: tree.folder.deletingLastPathComponent().appendingPathComponent(
                zip.lastPathComponent
            ).path
        ))
        #expect(rig.statuses.last == RemoteDragStatus.asZip)
        controller.dragEnded(mayFinish: false)
    }

    /// Oleg, 2026-11-09: "let a user decide", in Finder as anywhere. Teams and Chrome drop what they
    /// read as the pointer enters, so that is when the key counts.
    @Test("each entry offers what Shift was then, the same zip again, and Finder alike")
    func shiftCountsOnEveryEntry() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("local-toggle")
        let controller = rig.start([tree.localEntry], route: .folderURL, backend: LocalBackend())
        rig.shift = true
        controller.pointerMoved()
        let zip = try #require(rig.readURL())

        rig.shift = false
        rig.reenter(controller)
        #expect(rig.readURL()?.path == tree.folder.path)

        rig.shift = true
        rig.reenter(controller)
        #expect(rig.readURL() == zip)

        rig.surface = .finder(processID: 10)
        controller.pointerMoved()
        #expect(rig.readURL() == zip)
        #expect(rig.statuses.last == RemoteDragStatus.asZip)
        rig.shift = false
        rig.reenter(controller)
        #expect(rig.readURL()?.path == tree.folder.path)
        #expect(rig.statuses.last == RemoteDragStatus.holdShiftAndReenter)
        controller.dragEnded(mayFinish: false)
    }

    /// What Oleg's six logged drops met: ⇧ pressed over Teams, the board rewritten, and the drop taking
    /// the folder anyway. So the press leaves the board alone and says what will work. The drag says
    /// nothing when only a key changes, so the watch's timer is what notices it.
    @Test("a Shift change over the app the pointer is in asks for a re-entry and changes no board")
    func shiftOverTheAppAsksForReentry() async throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("local-still")
        let controller = rig.start([tree.localEntry], route: .folderURL, backend: LocalBackend())
        controller.pointerMoved()
        #expect(rig.statuses.last == RemoteDragStatus.holdShiftAndReenter)

        rig.shift = true
        await until { rig.statuses.last == RemoteDragStatus.moveOutAndBackIn }
        #expect(rig.statuses.last == RemoteDragStatus.moveOutAndBackIn)
        controller.pointerMoved()
        #expect(controller.handoff.form == .folders)
        #expect(controller.handoff.board == .asBegun)

        rig.reenter(controller)
        let zip = try #require(rig.readURL())
        #expect(zip.lastPathComponent == "\(tree.name).zip")
        #expect(rig.statuses.last == RemoteDragStatus.asZip)

        rig.shift = false
        await until { rig.statuses.last == RemoteDragStatus.moveOutAndBackIn }
        #expect(controller.handoff.form == .zips)
        #expect(rig.readURL() == zip)
        controller.dragEnded(mayFinish: false)
    }

    // MARK: - A folder on a server

    @Test("without Shift a server's folder is staged and handed over as itself")
    func serverFolderIsStaged() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("server-tree")
        let controller = rig.start(
            [tree.remoteEntry], route: .downloadFolder, backend: MirrorBackend(mirror: tree.root)
        )

        controller.pointerMoved()
        let staged = try #require(rig.readURL())

        #expect(staged.lastPathComponent == tree.name)
        #expect(
            try String(contentsOf: staged.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "b"
        )
        #expect(controller.handoff.compression == .notStarted)
        controller.dragEnded(mayFinish: false)
    }

    @Test(
        "with Shift a server's folder is zipped from its staged tree, and Finder entered without it gets the tree"
    )
    func serverFolderIsStagedAndZipped() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("server")
        let controller = rig.start(
            [tree.remoteEntry], route: .downloadFolder, backend: MirrorBackend(mirror: tree.root)
        )

        rig.shift = true
        controller.pointerMoved()
        let zip = try #require(rig.readURL())
        #expect(zip.lastPathComponent == "\(tree.name).zip")
        #expect(try FolderZipListing.listing(zip) == tree.zipListing)

        rig.surface = .finder(processID: 10)
        rig.shift = false
        controller.pointerMoved()
        let staged = try #require(rig.readURL())
        #expect(staged.lastPathComponent == tree.name)
        #expect(
            try String(contentsOf: staged.appendingPathComponent("sub/b.txt"), encoding: .utf8) == "b"
        )
        controller.dragEnded(mayFinish: false)
    }

    // MARK: - The drag ending

    /// A drop is read after it lands, an upload for minutes, so what was taken stays until the next
    /// launch clears the temp root. What nobody took goes at once.
    @Test("the drag's end keeps what the drop took and removes the rest")
    func endKeepsWhatWasTaken() throws {
        for (surface, shift, keepsZip, keepsTree) in [
            (RemoteDragHandoff.Surface.otherApp(processID: 20), true, true, false),
            (.otherApp(processID: 20), false, false, true),
            (.finder(processID: 10), true, true, false),
            (.finder(processID: 10), false, false, true),
            (.neutral, true, false, false)
        ] {
            let (zip, staged) = try droppedServerFolder(on: surface, shift: shift, operation: .copy)
            #expect(FileManager.default.fileExists(atPath: zip.path) == keepsZip, "\(surface)")
            #expect(FileManager.default.fileExists(atPath: staged.path) == keepsTree, "\(surface)")
            // What the drop kept would wait for the next launch; a test does not leave it there.
            RemoteDragArtifacts.remove(holderOf: zip)
            RemoteDragArtifacts.remove(holderOf: staged)
        }
        let (zip, staged) = try droppedServerFolder(
            on: .otherApp(processID: 20), shift: true, operation: []
        )
        #expect(!FileManager.default.fileExists(atPath: zip.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
    }

    /// Drag a server folder into another app with Shift, and again without, so both artifacts are
    /// known, then drop over `surface` entered with Shift as `shift` says. Returns the zip and the tree.
    private func droppedServerFolder(
        on surface: RemoteDragHandoff.Surface,
        shift: Bool,
        operation: NSDragOperation
    ) throws -> (URL, URL) {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("end")
        let controller = rig.start(
            [tree.remoteEntry], route: .downloadFolder, backend: MirrorBackend(mirror: tree.root)
        )
        rig.shift = true
        controller.pointerMoved()
        let zip = try #require(rig.readURL())
        rig.shift = false
        rig.reenter(controller)
        let staged = try #require(rig.readURL())
        // Let go over `surface` after entering it with Shift as `shift` says.
        rig.surface = .neutral
        controller.pointerMoved()
        rig.surface = surface
        rig.shift = shift
        controller.pointerMoved()
        controller.dragEnded(mayFinish: false, operation: operation)
        return (zip, staged)
    }

    // MARK: - Failing and stopping

    /// Before folders were handed off, a drag with no file on a server could only fail extracting;
    /// a server's folder alone made that the wrong sentence.
    @Test("a server folder that fails to come down is a copy that failed, not an extraction")
    func failureTitleNamesTheServer() {
        let server = PanelViewController.handoffFailureTitle(
            for: [FolderZipTree.anyPath: .downloadFolder]
        )
        let archive = PanelViewController.handoffFailureTitle(for: [FolderZipTree.anyPath: .extract])
        #expect(server == String(localized: "Couldn’t copy this item from the server"))
        #expect(archive == String(localized: "Couldn’t extract from the archive"))
        #expect(PanelViewController.handoffFailureTitle(
            for: [FolderZipTree.anyPath: .extract, .local("/tmp/b"): .download]
        ) == server)
    }

    @Test("a zip that cannot be made says so, after the drag, and leaves nothing behind")
    func failedZipIsReported() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("fail")
        let controller = rig.start(
            [tree.localEntry], route: .folderURL, backend: LocalBackend(),
            writer: FailingZipWriter()
        )

        rig.shift = true
        controller.pointerMoved()
        #expect(rig.readURL() == nil)
        #expect(rig.statuses.last == RemoteDragStatus.compressionFailed)
        controller.dragEnded(mayFinish: false)

        let failure = try #require(rig.failures.first as? DragOutZipFailure)
        #expect(failure.folderName == tree.name)
        #expect(rig.failures.count == 1)
        #expect(FolderZipListing.left(named: "\(tree.name).zip").isEmpty)
    }

    /// The folder itself went, so a zip nobody ended up wanting is nothing to apologise for.
    @Test("a zip that failed is not reported once the app was entered again without Shift")
    func failedZipLetGoIsQuiet() throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("fail-let-go")
        let controller = rig.start(
            [tree.localEntry], route: .folderURL, backend: LocalBackend(),
            writer: FailingZipWriter()
        )
        rig.shift = true
        controller.pointerMoved()
        #expect(rig.readURL() == nil)

        rig.shift = false
        rig.reenter(controller)
        #expect(rig.readURL()?.path == tree.folder.path)
        controller.dragEnded(mayFinish: false, operation: .copy)
        #expect(rig.failures.isEmpty)
    }

    /// A zip serves nobody after the drag, so it is stopped however small the pane said the transfer
    /// was, and being stopped is nobody's failure.
    @Test("a drag that ends while zipping stops the zip and leaves nothing")
    func endStopsTheZip() async throws {
        let tree = try FolderZipTree.make()
        defer { tree.remove() }
        let rig = FolderZipRig("stop")
        let writer = BlockingZipWriter()
        let controller = rig.start(
            [tree.localEntry], route: .folderURL, backend: LocalBackend(), writer: writer
        )

        rig.shift = true
        controller.pointerMoved()
        #expect(controller.handoff.form == .zips)
        await until { writer.started }
        controller.dragEnded(mayFinish: true)
        await until { writer.wasCancelled }

        #expect(writer.wasCancelled)
        #expect(rig.failures.isEmpty)
        #expect(FolderZipListing.left(named: "\(tree.name).zip").isEmpty)
    }
}

@MainActor
private func until(_ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline, !condition() {
        try? await Task.sleep(for: .milliseconds(25))
    }
}
