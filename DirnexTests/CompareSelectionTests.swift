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

    private static func entry(_ name: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local("/dir/\(name)"),
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

    @Test("Two marked files are the pair, in display order")
    func markedPairInDisplayOrder() throws {
        // Marked bottom-up, so a result in display order can't be an accident of insertion order.
        let vc = Self.pane(
            listing: [Self.entry("a.txt"), Self.entry("b.txt"), Self.entry("c.txt")],
            marked: ["c.txt", "a.txt"]
        )
        let pair = try #require(vc.comparablePair())
        #expect(pair.0 == VFSPath.local("/dir/a.txt"))
        #expect(pair.1 == VFSPath.local("/dir/c.txt"))
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

    @Test("A marked pair outside the local filesystem is refused")
    func markedRemotePairRefused() {
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
