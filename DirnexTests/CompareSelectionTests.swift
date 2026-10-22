import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which two files Compare By Contents hands the diff tool (PLAN.md §M5).
///
/// Two gestures reach it — exactly two files marked in one pane, or one under each pane's cursor —
/// and the rules that matter are invisible in a screenshot: which gesture wins when both could
/// answer, which way round the pair comes out, and that a marked pair the tool can't take is
/// refused rather than quietly replaced by the cursors' pair.
///
/// The panes here are headless (the view is never loaded) and have no `host`, so `comparableCursorPair`
/// can never answer — which is exactly what makes the precedence assertions sharp: a non-`nil` result
/// can only have come from the marks, and a `nil` one can only mean the marks were declined.
@Suite("Compare: choosing the pair")
@MainActor
struct CompareSelectionTests {
    // MARK: - Fixtures

    private static func entry(
        _ name: String,
        kind: FileEntry.Kind = .file,
        modified: TimeInterval = 0
    ) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
            name: name,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: modified),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A pane listing `entries` at `/dir`, with `marked` (by leaf name) marked in it.
    private static func pane(listing entries: [FileEntry], marked: [String] = []) -> PanelViewController {
        let vc = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local("/dir"),
            restorationKey: nil
        )
        let listing = DirectoryListing(path: .local("/dir"), entries: entries)
        vc.panel = Panel(model: DirectoryModel(listing: listing))
        vc.panel.setSelection(Set(entries.filter { marked.contains($0.name) }.map(\.path)))
        return vc
    }

    // MARK: - Two marks in one pane

    /// The case seen live: a copy sorts above its original by name, and the copy is the one edited.
    @Test("Two marked files are the pair, the older one on the left wherever it sorts")
    func markedPairOlderFirst() throws {
        let vc = Self.pane(
            listing: [
                Self.entry("test copy.txt", modified: 2000),
                Self.entry("test.txt", modified: 1000)
            ],
            marked: ["test copy.txt", "test.txt"]
        )
        // The copy is the upper row, so an older-first answer had to reorder the pair.
        #expect(vc.selectionTargets().map(\.name) == ["test copy.txt", "test.txt"])
        let pair = try #require(vc.comparablePair())
        #expect(pair.0.path == VFSPath.local("/dir/test.txt"))
        #expect(pair.1.path == VFSPath.local("/dir/test copy.txt"))
    }

    /// The control for the one above: with the dates the other way round the pair keeps display
    /// order, so that result came from the dates and not from a rule that always reverses.
    @Test("A marked pair already older-first keeps display order")
    func markedPairAlreadyOlderFirst() throws {
        let vc = Self.pane(
            listing: [
                Self.entry("test copy.txt", modified: 1000),
                Self.entry("test.txt", modified: 2000)
            ],
            marked: ["test copy.txt", "test.txt"]
        )
        let pair = try #require(vc.comparablePair())
        #expect(pair.0.path == VFSPath.local("/dir/test copy.txt"))
        #expect(pair.1.path == VFSPath.local("/dir/test.txt"))
    }

    @Test("Two marked files of the same age are the pair in display order")
    func markedPairOfOneAgeInDisplayOrder() throws {
        // Marked bottom-up, so a result in display order can't be an accident of insertion order.
        let vc = Self.pane(
            listing: [Self.entry("a.txt"), Self.entry("b.txt"), Self.entry("c.txt")],
            marked: ["c.txt", "a.txt"]
        )
        let pair = try #require(vc.comparablePair())
        #expect(pair.0.path == VFSPath.local("/dir/a.txt"))
        #expect(pair.1.path == VFSPath.local("/dir/c.txt"))
    }

    @Test("Two marks answer even with nothing under the other pane's cursor")
    func markedPairWinsOverCursors() {
        // No host, so the cursor pair is unavailable: an answer here is the marks' alone. Reversing
        // the precedence would make the marked gesture unreachable in the app, where both cursors
        // are almost always on something.
        let vc = Self.pane(
            listing: [Self.entry("a.txt"), Self.entry("b.txt")],
            marked: ["a.txt", "b.txt"]
        )
        #expect(vc.comparablePair() != nil)
        #expect(vc.canCompareByContents)
    }

    @Test("A marked pair that isn't two files is refused, not swapped for the cursors' pair")
    func markedFolderRefused() {
        let vc = Self.pane(
            listing: [Self.entry("a.txt"), Self.entry("sub", kind: .directory)],
            marked: ["a.txt", "sub"]
        )
        #expect(vc.comparablePair() == nil)
    }

    /// **Inverted by M24 Slice 4**, which is the point of keeping it: two archive members used to
    /// be refused by a `backend == .local` gate, and nothing about comparing two files ever needed
    /// them to be on this disk — only to *be files*. The bytes are brought down by the gesture and
    /// `ByteComparator` still only ever sees local paths.
    @Test("A marked pair inside an archive is a pair, not a refusal")
    func markedArchivePairIsAPair() throws {
        let backend = VFSBackendID.archive(forArchiveAt: "/dir/pkg.zip")
        let members = ["one.txt", "two.txt"].map { name in
            FileEntry(
                path: VFSPath(backend: backend, path: "/\(name)"),
                name: name,
                kind: .file,
                byteSize: 0,
                modificationDate: Date(timeIntervalSince1970: 0),
                creationDate: Date(timeIntervalSince1970: 0),
                isHidden: false,
                permissions: 0o644,
                inode: 0
            )
        }
        let vc = Self.pane(listing: members, marked: ["one.txt", "two.txt"])
        let pair = try #require(vc.comparablePair())
        #expect(pair.0.path == VFSPath(backend: backend, path: "/one.txt"))
        #expect(pair.1.path == VFSPath(backend: backend, path: "/two.txt"))
        #expect(vc.canCompareByContents)
    }

    /// The narrowness control for the line above: what `comparableEntries` still refuses is a row
    /// with no contents to compare, whichever backend it is on. Without it, "an archive member is
    /// comparable" would quietly become "anything is".
    @Test("A folder inside an archive is still refused")
    func markedArchiveFolderRefused() {
        let backend = VFSBackendID.archive(forArchiveAt: "/dir/pkg.zip")
        let rows = [("one.txt", FileEntry.Kind.file), ("sub", .directory)].map { name, kind in
            FileEntry(
                path: VFSPath(backend: backend, path: "/\(name)"),
                name: name,
                kind: kind,
                byteSize: 0,
                modificationDate: Date(timeIntervalSince1970: 0),
                creationDate: Date(timeIntervalSince1970: 0),
                isHidden: false,
                permissions: 0o644,
                inode: 0
            )
        }
        let vc = Self.pane(listing: rows, marked: ["one.txt", "sub"])
        #expect(vc.comparablePair() == nil)
    }

    // MARK: - Anything but two marks falls through to the cursors

    @Test("One mark falls through to the two panes' cursors", arguments: [
        [] as [String], ["b.txt"], ["a.txt", "b.txt", "c.txt"]
    ])
    func otherMarkCountsFallThrough(marked: [String]) {
        // Same headless pane, so falling through is observable as `nil`: only a two-mark selection
        // can be answered without a window.
        let vc = Self.pane(
            listing: [Self.entry("a.txt"), Self.entry("b.txt"), Self.entry("c.txt")],
            marked: marked
        )
        #expect(vc.comparablePair() == nil)
    }

    // MARK: - The `..` row

    @Test("The synthetic `..` row is not a cursor file")
    func parentRowIsNotAFile() {
        // `..` is not a model row — it carries its own flag — so `currentEntry` there answers with
        // the listing's *first* file, which would compare a file nobody pointed at.
        let vc = Self.pane(listing: [Self.entry("a.txt")])
        #expect(PanelViewController.cursorFile(of: vc)?.name == "a.txt")
        vc.cursorOnParentRow = true
        #expect(PanelViewController.cursorFile(of: vc) == nil)
    }
}
