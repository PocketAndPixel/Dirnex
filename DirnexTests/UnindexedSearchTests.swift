import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌥F7 in a folder Spotlight does not index (PLAN.md §M40 Slice 3): Spotlight is asked, the folder
/// is walked with its tags and text read off each file, and the dialog says so.
///
/// Every folder here is a fresh one under the temporary directory, which Spotlight never indexes on
/// any Mac, so these hold on a CI machine with indexing off as well as on this one. Whether an
/// *indexed* folder is recognized depends on the machine's index, and is checked in the live run.
@MainActor
@Suite("Find Files where Spotlight does not index")
struct UnindexedSearchTests {
    /// A fresh folder under the temporary directory, removed by the caller.
    private static func makeFolder() throws -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-unindexed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    private static func pane(at folder: String) -> PanelViewController {
        let path = VFSPath.local(folder)
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return pane
    }

    /// Polled for up to 120 s. The search hops on and off the main actor several times, and in a
    /// parallel run of the whole app suite one hop can wait tens of seconds (docs/NOTES.md ▸ Testing);
    /// a satisfied condition returns on the next poll, so the budget costs nothing when all is well.
    private static func until(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// The panes of walks that outlived their tests, kept for the rest of the run.
    private static var outlived: [PanelViewController] = []

    /// Wait for a walk to land, and if it outlives the wait, keep its pane. The caller removes the
    /// folder only after a wait that succeeded, so a late walk still finds it.
    ///
    /// Measured 2026-11-18 in a full parallel run: the first walk landed after this suite's old 30 s
    /// wait, the test returned and deleted the folder, and the second walk then failed to list it.
    /// With no window `presentOperationFailure` is `runModal()`, an app-modal alert that held the main
    /// actor and every suite behind it until the run was killed (the `ArchiveAddReachTests` trap).
    private static func finish(
        holding pane: PanelViewController,
        until isDone: @MainActor () -> Bool
    ) async -> Bool {
        if await until(isDone) { return true }
        outlived.append(pane)
        Issue.record("the walk did not land in 120 s; its pane and folder are kept for the run")
        return false
    }

    @Test("a fresh folder under the temporary directory is not covered")
    func temporaryFolderIsNotCovered() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        #expect(await !SpotlightCoverageCheck.covers(localFolder: folder))
    }

    /// The route end to end in the pane: what `mdfind` would have answered here is nothing, so a hit
    /// at all is the walk's.
    @Test("a search there walks the folder and reads tags and text off each file")
    func walksTheFolder() async throws {
        let folder = try Self.makeFolder()
        let notes = folder + "/notes"
        try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
        try Data("Квартальный invoice".utf8).write(to: URL(fileURLWithPath: notes + "/report.txt"))
        try Data("nothing here".utf8).write(to: URL(fileURLWithPath: notes + "/plain.txt"))
        var binary = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0x0D])
        binary.append(Data("invoice".utf8))
        try binary.write(to: URL(fileURLWithPath: notes + "/image.png"))
        try FinderTagStorage.setTags([FinderTag(name: "Work")], at: .local(notes + "/plain.txt"))

        let pane = Self.pane(at: folder)
        let place = SearchPlace(folder: .local(folder), everything: false)

        pane.runSearch(FileQuery(contentContains: "INVOICE"), in: place)
        guard await Self.finish(holding: pane, until: { pane.isSearchResults }) else { return }
        #expect(pane.panel.model.listing.entries.map(\.name) == ["report.txt"])

        let tabsBefore = pane.tabs.count
        pane.runSearch(FileQuery(tags: ["work"]), in: place)
        guard await Self.finish(holding: pane, until: { pane.tabs.count > tabsBefore })
        else { return }
        #expect(pane.panel.model.listing.entries.map(\.name) == ["plain.txt"])
        try? FileManager.default.removeItem(atPath: folder)
    }

    @Test("the dialog grows to say the folder is searched file by file")
    func dialogNote() throws {
        let controller = SearchController(
            currentFolderName: "media",
            fields: .indexed,
            connectionRootTitle: nil
        )
        let window = NSWindow(contentViewController: controller)
        window.layoutIfNeeded()
        let before = window.frame.height
        #expect(!controller.isShowingUnindexedNote)

        controller.showUnindexedNote()
        window.layoutIfNeeded()
        #expect(controller.isShowingUnindexedNote)
        #expect(window.frame.height > before, "the stack would otherwise compress the rows")
        let labels = Self.labels(in: controller.view)
        #expect(labels.contains { $0.contains("“media”") && $0.contains("plain-text") })
    }

    /// The pane's half: it asks while the dialog is up, and the note follows the answer.
    @Test("⌥F7 in such a folder puts the note up once Spotlight has answered")
    func paneShowsTheNote() async throws {
        let folder = try Self.makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let pane = Self.pane(at: folder)
        let controller = pane.makeSearchController(searching: .local(folder))
        controller.loadViewIfNeeded()
        pane.noteIfUnindexed(.local(folder), in: controller)
        #expect(await Self.until { controller.isShowingUnindexedNote })
    }

    private static func labels(in root: NSView) -> [String] {
        var labels: [String] = []
        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, !field.isEditable { labels.append(field.stringValue) }
            stack += view.subviews
        }
        return labels
    }
}
