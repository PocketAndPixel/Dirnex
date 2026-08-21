import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A search snapshot keeps its row after the app renames it.
///
/// It is the one listing here that can neither re-list nor re-gather itself: `refreshCurrentDirectory`
/// returns without touching a `search:` pane, and `refreshTree` deliberately skips a results root —
/// both saying that a snapshot keeps the hits it was given. Right for the world changing underneath
/// it; wrong for a change *this pane* just made, which would leave the row drawing a name that is no
/// longer on disk. That stale-name symptom is exactly how the S3 rename bug was first reported
/// (2026-08-22), so enabling rename in a snapshot without this would have shipped the complaint.
@MainActor
@Suite("A renamed search hit")
struct SearchHitRenameTests {
    private static let results = VFSPath(backend: .search, path: "/Results")

    private static func hit(_ name: String, in directory: String) -> FileEntry {
        FileEntry(
            path: .local("\(directory)/\(name)"),
            name: name,
            kind: .file,
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

    @Test("shows its new name without the search being run again")
    func substitutesTheRow() {
        let old = Self.hit("old.txt", in: "/Users/tester/Documents")
        let pane = Self.pane([old, Self.hit("other.txt", in: "/Users/tester/Desktop")])

        pane.substituteSearchHit(old.path, renamedTo: "new.txt")

        let names = pane.panel.model.listing.entries.map(\.name).sorted()
        #expect(names == ["new.txt", "other.txt"])
        // In place, in its own directory — a hit is addressed by where it really is, so a rename
        // that re-rooted it under the synthetic `search:` container would point at nothing.
        let renamed = pane.panel.model.listing.entries.first { $0.name == "new.txt" }
        #expect(renamed?.path == .local("/Users/tester/Documents/new.txt"))
        // And the cursor follows it, rather than staying on whatever index the re-sort left there.
        #expect(pane.panel.currentEntry?.name == "new.txt")
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
            pane.substituteSearchHit(old.path, renamedTo: "new.txt")
            #expect(pane.panel.model.listing.entries.map(\.name) == ["old.txt"], "\(path.backend)")
        }
    }

    /// A rename somewhere else in the tree is not this snapshot's business — a row inside an expanded
    /// folder is re-listed by `refreshTree`, which does reach real child directories.
    @Test("a path the snapshot does not hold changes nothing")
    func ignoresAPathItDoesNotHold() {
        let pane = Self.pane([Self.hit("old.txt", in: "/Users/tester/Documents")])
        pane.substituteSearchHit(.local("/Users/tester/Documents/sub/deep.txt"), renamedTo: "x.txt")
        #expect(pane.panel.model.listing.entries.map(\.name) == ["old.txt"])
    }
}
