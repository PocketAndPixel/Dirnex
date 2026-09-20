import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Put Back over a network share's own `#recycle` bin — the **wiring**, which the core's
/// `ShareRecycleBinTests` cannot see (2026-09-20).
///
/// Two seams, and the failure mode of each is silence rather than a wrong answer, which is why
/// both are pinned here rather than left to the path arithmetic being right:
///
/// - ``TrashOriginIndex`` is the one place a put-back origin is resolved, and its own doc comment
///   says it is internal so the merge can be driven directly — "a wiring that quietly stopped
///   consulting the store would be invisible everywhere else". A third source inherits that
///   exactly: unconsulted, every `#recycle` item simply reports "don't know where this came from",
///   which reads as the feature not being built.
/// - `putBackTargets` is the gate the command is offered through. Answering `[]` there is the
///   "opt-in seam whose default is *no*" family in docs/NOTES.md: the menu item is gray, nothing
///   logs, and both suites stay green.
@MainActor
@Suite("Share recycle bin Put Back")
struct ShareRecycleBinPutBackTests {
    private static let bin = VFSPath.local("/Volumes/home/#recycle")

    private func entry(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .file,
            byteSize: 3,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    /// A pane standing in `directory`, showing exactly `entries`, with the first one marked.
    ///
    /// The view is deliberately **not** loaded: `putBackTargets` reads the model and the tab's own
    /// `cursorOnParentRow`, never the table, so loading it would buy no coverage and cost this
    /// suite the main-actor stalls a full run's live panes produce (docs/NOTES.md ▸ Testing, "a
    /// test that loads a pane's *view* pays for every other suite's layout").
    private func pane(at directory: VFSPath, showing entries: [FileEntry]) -> PanelViewController {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: directory, entries: entries))
        )
        pane.panel.toggleMark(at: 0)
        return pane
    }

    // MARK: - The origin source

    /// The reach test. Nothing is recorded anywhere — no `.DS_Store`, no ``TrashOriginStore`` entry
    /// — because a `#recycle` item has neither; the bin's own layout is the entire answer.
    @Test("the restore index resolves a #recycle item from the path alone")
    func indexResolvesFromTheBinLayout() {
        var index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        let item = Self.bin.appending("probe").appending("nested.txt")
        #expect(index.origin(of: item)?.destination == .local("/Volumes/home/probe/nested.txt"))
    }

    /// The narrowness half, and the one that stops "resolve from the path" quietly becoming
    /// "resolve anything from its own parent" — which would hand every unrecorded item in a real
    /// Trash a confident wrong origin one directory up.
    @Test("an item outside a bin still has no origin without a record")
    func indexStillRefusesAnOrdinaryItem() {
        var index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        #expect(index.origin(of: .local("/Users/x/.Trash/a.txt")) == nil)
    }

    // MARK: - The gate the command is offered through

    @Test("a row inside a #recycle offers Put Back")
    func gateAnswersInsideABin() {
        let item = Self.bin.appending("DSCF8564.JPG")
        let pane = pane(at: Self.bin, showing: [entry(item)])
        #expect(pane.putBackTargets.map(\.path) == [item])
    }

    @Test("a row in an ordinary folder does not")
    func gateRefusesOutsideABin() {
        let directory = VFSPath.local("/Volumes/home")
        let pane = pane(at: directory, showing: [entry(directory.appending("DSCF8566.JPG"))])
        #expect(pane.putBackTargets.isEmpty)
    }

    /// The bin itself is a row in the share, and "putting it back" would mean moving the share's
    /// own recycle folder out of the share.
    @Test("the bin folder itself is not offered Put Back")
    func gateRefusesTheBinItself() {
        let share = VFSPath.local("/Volumes/home")
        let pane = pane(at: share, showing: [entry(Self.bin)])
        #expect(pane.putBackTargets.isEmpty)
    }

    /// All of them or none: a tree can put a bin's contents beside rows that are in no bin, and
    /// restoring the half that can go home would report the rest as failures nobody asked about.
    @Test("a mixed selection offers nothing rather than half a restore")
    func gateRefusesAMixedSelection() {
        let share = VFSPath.local("/Volumes/home")
        let inBin = entry(Self.bin.appending("a.txt"))
        let outside = entry(share.appending("b.txt"))
        let pane = pane(at: share, showing: [inBin, outside])
        pane.panel.toggleMark(at: 1)
        #expect(pane.panel.selectionCount == 2)
        #expect(pane.putBackTargets.isEmpty)
    }

    // MARK: - The move itself, against a real filesystem

    /// A temp directory laid out the way a share is: a `#recycle` holding `<relative>`, and the
    /// original chain **absent**, which is the ordinary state (the folder was deleted too).
    private func share(withRecycled relative: String) throws -> VFSPath {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recycle-\(UUID().uuidString)")
        let file = root.appendingPathComponent("#recycle").appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "restore me\n".write(to: file, atomically: true, encoding: .utf8)
        return .local(root.path)
    }

    private func exists(_ path: VFSPath) -> Bool {
        FileManager.default.fileExists(atPath: path.path)
    }

    /// The live run in one test: the file goes home to the mirrored path, the folder chain that no
    /// longer existed is rebuilt, and the empty scaffolding it left in the bin is swept.
    @Test("a restore rebuilds the vanished folder and leaves no scaffolding in the bin")
    func restoreRebuildsTheChainAndPrunesTheBin() throws {
        let root = try share(withRecycled: "probe/sub/nested.txt")
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let item = root.appending("#recycle").appending("probe").appending("sub")
            .appending("nested.txt")
        let origin = try #require(ShareRecycleBin.origin(of: item))

        let index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        _ = index.putBack(item, to: origin)

        #expect(exists(root.appending("probe").appending("sub").appending("nested.txt")))
        #expect(exists(item) == false)
        #expect(exists(root.appending("#recycle").appending("probe")) == false)
        // Never above the bin: the share's own recycle folder has to survive emptying itself.
        #expect(exists(root.appending("#recycle")))
    }

    /// The narrowness half of the prune, and the one that stops it becoming a recursive delete: a
    /// sibling still waiting in the bin keeps its folder.
    @Test("the prune stops at a folder that still holds something")
    func pruneStopsAtANonEmptyFolder() throws {
        let root = try share(withRecycled: "probe/sub/nested.txt")
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let sub = root.appending("#recycle").appending("probe").appending("sub")
        let sibling = sub.appending("keep.txt")
        try "keep\n".write(to: URL(fileURLWithPath: sibling.path), atomically: true, encoding: .utf8)
        let item = sub.appending("nested.txt")

        let index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        _ = index.putBack(item, to: try #require(ShareRecycleBin.origin(of: item)))

        #expect(exists(root.appending("probe").appending("sub").appending("nested.txt")))
        #expect(exists(sibling))
        #expect(exists(sub))
    }

    /// The inherited rule, meeting a bin for the first time: a name that has since come back at the
    /// original path is **not** replaced, and the item stays where it was.
    @Test("a restore never overwrites something already back at the original path")
    func restoreRefusesToOverwrite() throws {
        let root = try share(withRecycled: "report.txt")
        defer { try? FileManager.default.removeItem(atPath: root.path) }
        let destination = root.appending("report.txt")
        try "the newer one\n".write(
            to: URL(fileURLWithPath: destination.path), atomically: true, encoding: .utf8
        )
        let item = root.appending("#recycle").appending("report.txt")

        let index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        _ = index.putBack(item, to: try #require(ShareRecycleBin.origin(of: item)))

        #expect(try String(contentsOfFile: destination.path, encoding: .utf8) == "the newer one\n")
        #expect(exists(item))
    }
}
