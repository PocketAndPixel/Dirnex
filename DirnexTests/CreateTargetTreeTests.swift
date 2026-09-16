import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where F7 New Folder, ⇧F4 Edit File and a paste land in a **tree**, and what their dialogs call it
/// (`PanelViewController+CreateTarget`).
///
/// The merged iCloud listing is the subject because it is the one tree whose root-level rows do not
/// share a directory with the pane: loose rows live in `com~apple~CloudDocs`, and an app library's
/// row is a `Documents` folder inside the app's own container. Taking each row's parent put the
/// create in one of those, and named the first one in the dialog (seen live 2026-09-16:
/// «Create a folder in “com~apple~CloudDocs”»). Every case moves the cursor within one pane, because
/// the claim is that the answer depends on the row's *level* and on nothing else.
@MainActor
@Suite("Where a create lands in a tree")
struct CreateTargetTreeTests {
    /// Paths under this Mac's real CloudDocs container. `writeDirectory` reads that container for the
    /// merged listing, so a fixture in a temp tree (the core's `ICloudFixture`, which also builds the
    /// merge `PanelCursorDirectoryTests` uses) could not stand in for it here.
    private enum MergedICloud {
        static var hasContainer: Bool { SidebarLocations.iCloudDrive() != nil }

        static func container() throws -> VFSPath {
            try #require(SidebarLocations.iCloudDrive())
        }

        static func pagesDocuments(_ container: VFSPath) throws -> VFSPath {
            try #require(container.parent).appending("com~apple~Pages").appending("Documents")
        }
    }

    private static func entry(
        _ name: String,
        at path: VFSPath,
        kind: FileEntry.Kind = .directory
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }

    /// A tree over the merged listing, with the Pages library and the loose `Projects` folder
    /// expanded. Rows, folders first: `Pages`, `Letter.pages`, `Projects`, `plan.md`, `notes.txt`.
    private static func iCloudTreePane() throws -> PanelViewController {
        let container = try MergedICloud.container()
        let documents = try MergedICloud.pagesDocuments(container)
        let projects = container.appending("Projects")

        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: ICloudLocation.mergedPath,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: ICloudLocation.mergedPath,
            entries: [
                Self.entry("notes.txt", at: container.appending("notes.txt"), kind: .file),
                Self.entry("Projects", at: projects),
                // An app's name over its `Documents` folder (`ICloudDrive.libraryRow`).
                Self.entry("Pages", at: documents)
            ]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(
            documents,
            entries: [
                Self.entry("Letter.pages", at: documents.appending("Letter.pages"), kind: .file)
            ]
        )
        panel.setTreeChildListing(
            projects,
            entries: [Self.entry("plan.md", at: projects.appending("plan.md"), kind: .file)]
        )
        panel.expand(documents)
        panel.expand(projects)
        pane.panel = panel
        return pane
    }

    private static func rowNames(_ pane: PanelViewController) -> [String] {
        pane.panel.displayedEntries.map(\.name)
    }

    // MARK: - The merged listing

    /// The bug. Every root-level row creates where the same key creates in list mode — the CloudDocs
    /// container underneath — and the dialog names the pane, never the container. The library row is
    /// the worse half: its parent is `com~apple~Pages`, outside anything iCloud Drive shows.
    ///
    /// Skipped on a Mac with no iCloud container, where `writeDirectory` answers `nil` and there is
    /// nowhere to create at all.
    @Test(
        "a root-level row of the merged listing creates in the container and names the pane",
        .enabled(if: MergedICloud.hasContainer)
    )
    func rootLevelCreatesInTheContainer() throws {
        let pane = try Self.iCloudTreePane()
        let container = try MergedICloud.container()
        #expect(Self.rowNames(pane) == ["Pages", "Letter.pages", "Projects", "plan.md", "notes.txt"])

        for index in [0, 2, 4] {
            pane.panel.moveCursor(to: index)
            let row = Self.rowNames(pane)[index]
            #expect(pane.creationDirectory == container, "\(row)")
            #expect(pane.createsInPaneDirectory, "\(row)")
            #expect(pane.creationDirectoryName == CloudPlaceTitle.iCloudDrive(), "\(row)")
            // A paste reads the same property, so it lands in the same place.
            #expect(pane.pasteDestination == container, "\(row)")
        }
    }

    /// The narrowness control inside the merge: a row an expanded folder's listing put there lives
    /// where its path says. Without it, "always the container" passes the test above and creates
    /// every deeper item back at the root.
    @Test(
        "a deeper row inside the merged listing still creates in its own folder",
        .enabled(if: MergedICloud.hasContainer)
    )
    func deeperLevelCreatesInItsFolder() throws {
        let pane = try Self.iCloudTreePane()
        let container = try MergedICloud.container()

        pane.panel.moveCursor(to: 1) // Pages ▸ Letter.pages
        let documents = try MergedICloud.pagesDocuments(container)
        #expect(pane.creationDirectory == documents)
        #expect(!pane.createsInPaneDirectory)
        // Named as the row above it is drawn, never as the folder's real name (`VFSPathDisplayNameTests`).
        #expect(pane.creationDirectoryName == documents.displayName)
        #expect(pane.creationDirectoryName != "Documents")

        pane.panel.moveCursor(to: 3) // Projects ▸ plan.md
        #expect(pane.creationDirectory == container.appending("Projects"))
        #expect(!pane.createsInPaneDirectory)
        #expect(pane.creationDirectoryName == "Projects")
    }

    // MARK: - An ordinary folder

    /// The control that needs no iCloud: in a tree over a real folder the root level and the pane are
    /// the same directory, and a deeper row still creates beside itself — so neither half of the
    /// rule moved anything here.
    @Test("a tree over an ordinary folder creates at the root, and beside a deeper row")
    func ordinaryTreeIsUnchanged() {
        let root = VFSPath.local("/Users/tester/Work")
        let docs = root.appending("docs")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: root,
            restorationKey: nil
        )
        var panel = Panel(model: DirectoryModel(listing: DirectoryListing(
            path: root,
            entries: [
                Self.entry("docs", at: docs),
                Self.entry("z.txt", at: root.appending("z.txt"), kind: .file)
            ]
        )))
        panel.enterTreeMode()
        panel.setTreeChildListing(
            docs,
            entries: [Self.entry("a.txt", at: docs.appending("a.txt"), kind: .file)]
        )
        panel.expand(docs)
        pane.panel = panel
        #expect(Self.rowNames(pane) == ["docs", "a.txt", "z.txt"])

        pane.panel.moveCursor(to: 2)
        #expect(pane.creationDirectory == root)
        #expect(pane.createsInPaneDirectory)
        #expect(pane.creationDirectoryName == "Work")

        pane.panel.moveCursor(to: 1)
        #expect(pane.creationDirectory == docs)
        #expect(!pane.createsInPaneDirectory)
        #expect(pane.creationDirectoryName == "docs")
    }
}
