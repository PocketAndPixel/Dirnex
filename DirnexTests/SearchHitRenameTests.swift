import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A search snapshot keeps its rows where they really are after the app renames something.
///
/// It is the one listing here that can neither re-list nor re-gather itself: `refreshCurrentDirectory`
/// returns without touching a `search:` pane, and `refreshTree` deliberately skips a results root —
/// both saying that a snapshot keeps the hits it was given. Right for the world changing underneath
/// it; wrong for a change *the app* just made, which would leave the row drawing a name that is no
/// longer on disk. That stale-name symptom is exactly how the S3 rename bug was first reported
/// (2026-08-22), so enabling rename in a snapshot without this would have shipped the complaint.
///
/// **Since 2026-11-05 a hit inside a renamed folder moves with it, in every results tab of both
/// panes**, where the original substitution put back only the renamed row and only in the tab the
/// rename ran in. The fold itself is pinned in the core's `SearchSnapshotRenameTests`; what is
/// pinned here is that the pane applies it to the tabs it should and leaves the rest alone.
@MainActor
@Suite("A renamed search hit")
struct SearchHitRenameTests {
    private static let results = VFSPath(backend: .search, path: "/Results")

    private static func hit(_ name: String, in directory: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local("\(directory)/\(name)"),
            name: name,
            kind: kind,
            byteSize: 128,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 900_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    private static func pane(_ entries: [FileEntry], at path: VFSPath = results) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: entries),
            sort: FileSort(key: .name)
        ))
        return pane
    }

    private static func renamed(_ from: String, _ to: String) -> SearchSnapshot.Renamed {
        SearchSnapshot.Renamed(from: .local(from), to: .local(to))
    }

    private static func paths(_ panel: Panel) -> [String] {
        panel.model.listing.entries.map(\.path.path).sorted()
    }

    @Test("shows its new name without the search being run again")
    func substitutesTheRow() {
        let old = Self.hit("old.txt", in: "/Users/tester/Documents")
        let pane = Self.pane([old, Self.hit("other.txt", in: "/Users/tester/Desktop")])
        let destination = VFSPath.local("/Users/tester/Documents/new.txt")

        pane.noteSearchHitsRenamed(
            [SearchSnapshot.Renamed(from: old.path, to: destination)], landing: destination
        )

        let names = pane.panel.model.listing.entries.map(\.name).sorted()
        #expect(names == ["new.txt", "other.txt"])
        // In place, in its own directory — a hit is addressed by where it really is, so a rename
        // that re-rooted it under the synthetic `search:` container would point at nothing.
        let renamed = pane.panel.model.listing.entries.first { $0.name == "new.txt" }
        #expect(renamed?.path == destination)
        // And the cursor follows it, rather than staying on whatever index the re-sort left there.
        #expect(pane.panel.currentEntry?.name == "new.txt")
    }

    /// The reported case: F2 on a folder that is a hit, with a hit inside it. The inner hit used to
    /// keep the folder's old name in its path, which addresses nothing.
    @Test("a hit inside a renamed folder moves with it")
    func carriesHitsInsideARenamedFolder() {
        let pane = Self.pane([
            Self.hit("docs", in: "/Users/tester", kind: .directory),
            Self.hit("a.txt", in: "/Users/tester/docs"),
            Self.hit("docs2.txt", in: "/Users/tester")
        ])

        pane.noteSearchHitsRenamed([Self.renamed("/Users/tester/docs", "/Users/tester/guides")])

        #expect(Self.paths(pane.panel) == [
            "/Users/tester/docs2.txt", "/Users/tester/guides", "/Users/tester/guides/a.txt"
        ])
        // The inner hit keeps its own name; only its folder changed.
        #expect(pane.panel.model.listing.entries.contains { $0.name == "a.txt" })
    }

    /// A delete or a move has always reached every results tab, because the question is about the
    /// file and not about the tab the gesture ran in. A rename now does too, and a background tab's
    /// cursor follows its own row rather than jumping to the gesture's landing.
    @Test("every results tab in both panes is updated, and a folder tab is not")
    func reachesEveryResultsTab() {
        let inside = Self.hit("a.txt", in: "/Users/tester/docs")
        let pane = Self.pane([inside])
        let other = PanelTab(panel: Panel(model: DirectoryModel(
            listing: DirectoryListing(path: Self.results, entries: [inside]),
            sort: FileSort(key: .name)
        )))
        let folder = PanelTab(panel: Panel(model: DirectoryModel(
            listing: DirectoryListing(path: .local("/Users/tester/docs"), entries: [inside]),
            sort: FileSort(key: .name)
        )))
        pane.tabs.append(other)
        pane.tabs.append(folder)
        let counterpart = Self.pane([inside])
        let host = StubPanelHost()
        host.counterpart = counterpart
        pane.host = host

        pane.noteSearchHitsRenamed([Self.renamed("/Users/tester/docs", "/Users/tester/guides")])

        #expect(Self.paths(pane.panel) == ["/Users/tester/guides/a.txt"])
        #expect(Self.paths(other.panel) == ["/Users/tester/guides/a.txt"])
        #expect(Self.paths(counterpart.panel) == ["/Users/tester/guides/a.txt"])
        #expect(other.panel.currentEntry?.path == .local("/Users/tester/guides/a.txt"))
        // A real folder re-lists on its own; rewriting it here would race that re-list.
        #expect(Self.paths(folder.panel) == ["/Users/tester/docs/a.txt"])
    }

    /// The narrowness control: this is a repair for a listing that cannot refresh itself, so it must
    /// not touch one that can. A real directory, the merged Trash and the merged iCloud listing all
    /// re-list or re-gather on `refreshCurrentDirectory`, and a substitution here would race that.
    @Test("a listing that can refresh itself is left alone")
    func leavesRefreshableListingsAlone() {
        for path in [
            VFSPath.local("/Users/tester/Documents"),
            VFSPath(backend: .trash, path: "/Trash"),
            VFSPath(backend: .icloud, path: "/iCloud Drive")
        ] {
            let old = Self.hit("old.txt", in: "/Users/tester/Documents")
            let pane = Self.pane([old], at: path)
            pane.noteSearchHitsRenamed(
                [Self.renamed(old.path.path, "/Users/tester/Documents/new.txt")]
            )
            #expect(pane.panel.model.listing.entries.map(\.name) == ["old.txt"], "\(path.backend)")
        }
    }

    /// A rename somewhere else in the tree is not this snapshot's business — a row inside an expanded
    /// folder is re-listed by `refreshTree`, which does reach real child directories.
    @Test("a path the snapshot does not hold changes nothing")
    func ignoresAPathItDoesNotHold() {
        let pane = Self.pane([Self.hit("old.txt", in: "/Users/tester/Documents")])
        pane.noteSearchHitsRenamed([
            Self.renamed("/Users/tester/Documents/sub/deep.txt", "/Users/tester/Documents/sub/x.txt")
        ])
        #expect(pane.panel.model.listing.entries.map(\.name) == ["old.txt"])
    }
}
