import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where ⌥F7 can run, and what the Find Files dialog offers once it does (PLAN.md §M22 Slice 2).
///
/// Two claims, and they fail in opposite directions. A pane that *can* be searched must offer it —
/// the `canGoToParent` lesson, where three spellings of one rule left every remote pane without a
/// `..` row for three milestones. And a pane that cannot must not silently search **somewhere
/// else**: an S3 account pane's rows are buckets, and falling back to this Mac's home folder because
/// the pane showed a bucket list would answer a question nobody asked, from a keystroke.
///
/// Both come from the real `canFindFiles` and the real `validateMenuItem`, driven against a pane
/// routing through a real `CompositeBackend` — a `LocalBackend` pane answers for itself at every
/// path and would pass whatever the routing did.
@MainActor
@Suite("Search's reach")
struct SearchReachTests {
    private static let bucket = S3Location(
        host: "s3.eu-central-1.amazonaws.com",
        bucket: "photos",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private static func pane(at path: VFSPath, connect: ((CompositeBackend) -> Void)? = nil)
        -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        // Registering a connection touches no network (`CompositeBackendTests`).
        connect?(composite)
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: [])
        ))
        return pane
    }

    private static func findItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.action = #selector(PanelViewController.findFiles(_:))
        return item
    }

    @Test("a folder, a bucket and an archive can all be searched")
    func searchableEverywhereItShouldBe() {
        let searchable: [VFSPath] = [
            .local("/Users/tester/Documents"),
            VFSPath(backend: .s3(Self.bucket), path: "/dir"),
            VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/"),
            // A virtual results listing has no directory of its own, and falls back to Home rather
            // than losing the command.
            VFSPath(backend: .trash, path: "/Trash")
        ]
        for path in searchable {
            let pane = Self.pane(at: path)
            #expect(pane.canFindFiles, "\(path.backend) should be searchable")
            #expect(pane.validateMenuItem(Self.findItem()), "\(path.backend) menu item")
        }
    }

    /// The one place it is refused, and the refusal has to reach the *menu item* as well — a
    /// validator carrying its own copy of the rule is how a command ends up gray where it works, or
    /// armed where it does not.
    @Test("an S3 account pane offers no search rather than searching this Mac")
    func accountPaneRefuses() {
        let pane = Self.pane(
            at: VFSPath(backend: .s3Account(Self.bucket.account), path: "/"),
            connect: { $0.connectS3Account(account: Self.bucket.account, secretAccessKey: "s") }
        )
        #expect(!pane.canFindFiles)
        #expect(!pane.validateMenuItem(Self.findItem()))
    }
}

/// F5 out of a results tab whose rows are **archive members** — the one thing a walking search made
/// reachable that nothing downstream expected (PLAN.md §M22 Slice 2).
///
/// Found live rather than by reasoning: a search inside `pkg.zip` produced a perfectly ordinary
/// results tab, and F5 on a hit failed *inside the queue* with "This location doesn't support
/// copying files" — `copyToOtherPane` routed on the **pane**, whose container is the synthetic
/// `search:` path, so the extraction route never ran and the byte copy reached `ArchiveBackend`,
/// which has no `copyFile`. The question has to be asked of the rows.
@MainActor
@Suite("Copying out of an archive search")
struct ArchiveResultRoutingTests {
    private static let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")

    private static func entry(_ name: String, on backend: VFSBackendID) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/docs/\(name)"),
            name: name,
            kind: .file,
            byteSize: 3,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    /// A pane on the synthetic results path, holding `entries` — the exact shape `openResults`
    /// installs after a walk.
    private static func resultsPane(holding entries: [FileEntry]) -> PanelViewController {
        let path = VFSPath(backend: .search, path: "/“report”")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: entries)
        ))
        return pane
    }

    /// The rows as the pane holds them, which is what `selectionTargets()` draws from.
    private func rows(of pane: PanelViewController) -> [FileEntry] {
        (0..<pane.panel.count).map { pane.panel.model[$0] }
    }

    @Test("hits from inside an archive are extracted, not byte-copied")
    func archiveHitsRouteToExtraction() {
        let pane = Self.resultsPane(holding: [Self.entry("report.txt", on: Self.archive)])
        #expect(pane.extractionArchivePath(for: rows(of: pane)) == "/tmp/pkg.zip")
    }

    /// The narrowness control, and the one that matters most: an ordinary Spotlight results tab
    /// must keep going through the byte-copy queue. Routing *everything* to the extractor would
    /// break every local search, which is the far more common case.
    @Test("ordinary local hits are left on the copy path")
    func localHitsAreUnaffected() {
        let pane = Self.resultsPane(holding: [Self.entry("report.txt", on: .local)])
        #expect(pane.extractionArchivePath(for: rows(of: pane)) == nil)
    }

    /// Extracting from two archives at once is a second job, not a second path through this one —
    /// so a mixed selection declines rather than silently extracting from whichever came first.
    @Test("a selection spanning two archives is not one extraction")
    func mixedArchivesDecline() {
        let other = VFSBackendID.archive(forArchiveAt: "/tmp/other.zip")
        let pane = Self.resultsPane(holding: [
            Self.entry("a.txt", on: Self.archive),
            Self.entry("b.txt", on: other)
        ])
        #expect(pane.extractionArchivePath(for: rows(of: pane)) == nil)
    }

    /// An archive *pane* keeps answering with its own archive whatever its rows say — the browse
    /// case, which is what this function did before and must go on doing.
    @Test("an archive pane still answers with its own archive")
    func archivePaneUnchanged() {
        let path = VFSPath(backend: Self.archive, path: "/docs")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: [])
        ))
        #expect(pane.extractionArchivePath(for: []) == "/tmp/pkg.zip")
    }
}

/// What the cursor's row is, in a results tab whose rows are **not files on this Mac** (PLAN.md §M22
/// Slice 5).
///
/// The milestone opened on the premise that a hit is reached "exactly as a local one is, with no
/// work", because a results tab's container is synthetic while every entry carries its real
/// `VFSPath`. That is true of the *paths* and false of the four properties that resolve them: each
/// asked `panel.path.backend`, which in a results tab says `search:`. So ⌃Q drew nothing, ⌘Y said
/// "No items selected", ⏎ inside a zip did nothing, and F4 said the file could not be edited — for
/// rows the browse route handles perfectly. Slice 2 found the same shape at F5 and fixed that one
/// site; Slices 3 and 4 then made remote hits real, which is what made the rest reachable.
///
/// Every assertion here has its narrowness control beside it, because the failure the fix could
/// introduce is the opposite one: answering for an ordinary *local* results tab would send every
/// Spotlight hit down the extraction or download path.
@MainActor
@Suite("Previewing a search hit")
struct SearchHitReachTests {
    private static let archive = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
    private static let bucket = VFSBackendID.s3(S3Location(
        host: "s3.example.com",
        bucket: "photos",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    ))

    private static func entry(_ name: String, on backend: VFSBackendID) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: backend, path: "/docs/\(name)"),
            name: name,
            kind: .file,
            byteSize: 3,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }

    /// A pane on the synthetic results path holding one hit — the shape `openResults` installs after
    /// a walk, with the cursor on row 0.
    private static func resultsPane(showing entry: FileEntry) -> PanelViewController {
        let path = VFSPath(backend: .search, path: "/“report”")
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: [entry])
        ))
        return pane
    }

    @Test("a hit inside an archive is a previewable member")
    func archiveHitIsPreviewable() throws {
        let pane = Self.resultsPane(showing: Self.entry("report.txt", on: Self.archive))
        let member = try #require(pane.previewableArchiveMember)
        #expect(member.archivePath == "/tmp/pkg.zip")
        #expect(member.innerPath == "/docs/report.txt")
    }

    @Test("an ordinary local hit is not an archive member")
    func localHitIsNotAMember() {
        let pane = Self.resultsPane(showing: Self.entry("report.txt", on: .local))
        #expect(pane.previewableArchiveMember == nil)
    }

    /// The remote twin. `remoteFileUnderCursor` is what both preview surfaces read to decide whether
    /// there is anything to fetch *and* what the placeholder card describes — so keyed on the pane it
    /// took away not just the preview but the card explaining its absence.
    @Test("a hit on a server is a fetchable remote file")
    func remoteHitIsFetchable() throws {
        let pane = Self.resultsPane(showing: Self.entry("DSC_0002.NEF", on: Self.bucket))
        let entry = try #require(pane.remoteFileUnderCursor)
        #expect(entry.name == "DSC_0002.NEF")
    }

    @Test("an ordinary local hit is not a remote file")
    func localHitIsNotRemote() {
        let pane = Self.resultsPane(showing: Self.entry("report.txt", on: .local))
        #expect(pane.remoteFileUnderCursor == nil)
    }

    /// ⌘Y's target list. `false` here sends the panel down the branch that keeps only `.local` rows,
    /// which is an empty list for every hit of a walking search — and an empty list is what Quick
    /// Look draws as "No items selected".
    @Test("a hit that is not on this Mac is previewed one file at a time")
    func nonLocalHitsAreCursorOnly() {
        for backend in [Self.archive, Self.bucket] {
            let pane = Self.resultsPane(showing: Self.entry("report.txt", on: backend))
            #expect(pane.previewsCursorFileOnly, "\(backend)")
        }
    }

    @Test("a local results tab keeps previewing whatever is marked")
    func localHitsKeepTheMarkedSet() {
        let pane = Self.resultsPane(showing: Self.entry("report.txt", on: .local))
        #expect(!pane.previewsCursorFileOnly)
    }

    /// F4 routes by the row already — and then died in the callee, which read the pane. The route is
    /// the half a test can see without launching an editor.
    @Test("F4 on a hit inside an archive edits the member rather than refusing")
    func archiveHitIsEditable() {
        let entry = Self.entry("report.txt", on: Self.archive)
        let pane = Self.resultsPane(showing: entry)
        #expect(pane.editRoute(for: entry) == .archiveMember)
    }

    /// A folder row is still not a thing to preview or edit, whichever backend it is on — the
    /// control that keeps "ask the row" from becoming "answer for every row".
    @Test("a folder hit is neither previewable nor editable")
    func folderHitsAreNeither() {
        let folder = FileEntry(
            path: VFSPath(backend: Self.archive, path: "/docs/sub"),
            name: "sub",
            kind: .directory,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 2
        )
        let pane = Self.resultsPane(showing: folder)
        #expect(pane.previewableArchiveMember == nil)
        #expect(pane.editRoute(for: folder) == .unavailable)
    }
}

/// What the dialog draws for a given scope.
///
/// The rows a place cannot answer are **hidden**, and that is the surface the milestone is really
/// about: nothing else in the app tells the user that a bucket has no text index, and a grayed-out
/// field would read as a setting they had failed to find.
@MainActor
@Suite("Find Files dialog")
struct SearchControllerTests {
    /// The dialog's grid, found through the view hierarchy rather than through a widened property —
    /// what is being asserted is what is on screen, so reading it the way the screen does keeps the
    /// test honest about that.
    private func grid(of controller: SearchController) -> NSGridView? {
        controller.loadViewIfNeeded()
        func search(_ view: NSView) -> NSGridView? {
            if let grid = view as? NSGridView { return grid }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        return search(controller.view)
    }

    /// Row order matches the dialog's: name, content, tags, kind, size, modified, scope.
    private enum RowIndex {
        static let content = 1
        static let tags = 2
        static let scope = 6
    }

    @Test("a local scope offers every field")
    func localOffersEverything() throws {
        let controller = SearchController(
            currentFolderName: "Documents",
            fields: .indexed,
            connectionRootTitle: nil
        )
        let grid = try #require(self.grid(of: controller))
        #expect(!grid.row(at: RowIndex.content).isHidden)
        #expect(!grid.row(at: RowIndex.tags).isHidden)
    }

    @Test("a server scope hides the fields it cannot answer")
    func remoteHidesContentAndTags() throws {
        let controller = SearchController(
            currentFolderName: "photos",
            fields: .listed,
            connectionRootTitle: "photos — s3.eu-central-1.amazonaws.com"
        )
        let grid = try #require(self.grid(of: controller))
        #expect(grid.row(at: RowIndex.content).isHidden)
        #expect(grid.row(at: RowIndex.tags).isHidden)
        // The narrowness control: hiding two rows must not have hidden the dialog. Without it,
        // "hide what cannot be answered" could quietly become "hide everything".
        #expect(!grid.row(at: 0).isHidden)
        #expect(!grid.row(at: RowIndex.scope).isHidden)
    }

    /// "Everywhere" is a claim about a Spotlight index that spans volumes. On a server there is no
    /// such thing, and the honest second option is the connection's own root — named, so it is
    /// obvious that "everything" stops at the bucket.
    @Test("the second scope option names the connection instead of promising everywhere")
    func scopeOptionNamesTheConnection() throws {
        let remote = SearchController(
            currentFolderName: "photos",
            fields: .listed,
            connectionRootTitle: "photos — s3.example.com"
        )
        let remoteGrid = try #require(grid(of: remote))
        let remotePopup = try #require(scopePopup(in: remoteGrid))
        #expect(remotePopup.itemTitles.count == 2)
        #expect(remotePopup.itemTitles[1].contains("photos — s3.example.com"))

        let local = SearchController(
            currentFolderName: "Documents",
            fields: .indexed,
            connectionRootTitle: nil
        )
        let localGrid = try #require(grid(of: local))
        let localPopup = try #require(scopePopup(in: localGrid))
        #expect(!localPopup.itemTitles[1].contains("Documents"))
    }

    private func scopePopup(in grid: NSGridView) -> NSPopUpButton? {
        grid.cell(atColumnIndex: 1, rowIndex: RowIndex.scope).contentView as? NSPopUpButton
    }
}
