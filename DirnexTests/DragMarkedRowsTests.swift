import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A drag that starts on a marked row carries every marked row, promises included, and the table
/// builds the session that way instead of widening its board afterwards (`FileTableView+Drag`).
///
/// Measured live 2026-10-24: the old widening rewrote the session's board in `willBeginAt`, which
/// carried two marked local zips into Finder and lost two marked WebDAV rows outright. A drag
/// session cannot be synthesized, so what is pinned is either side of it: the writers the pane hands
/// the table, and the items the table builds from them.
@MainActor
@Suite("Drag marked rows")
struct DragMarkedRowsTests {
    private static let remoteID = VFSBackendID("sftp://user@host")

    private static func entry(_ name: String) -> FileEntry {
        FileEntry(
            path: VFSPath(backend: remoteID, path: "/srv/\(name)"),
            name: name,
            kind: .file,
            byteSize: 4096,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 11
        )
    }

    /// A pane listing `a.txt`, `b.txt` and `c.txt` on a server, with `marked` (by name) marked.
    private static func pane(marked: [String]) -> PanelViewController {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: .local("/tmp"),
            restorationKey: nil
        )
        let entries = ["a.txt", "b.txt", "c.txt"].map(entry)
        let listing = DirectoryListing(
            path: VFSPath(backend: remoteID, path: "/srv"),
            entries: entries
        )
        pane.panel = Panel(model: DirectoryModel(listing: listing))
        pane.panel.setSelection(Set(entries.filter { marked.contains($0.name) }.map(\.path)))
        return pane
    }

    /// The writers a drag grabbed on `name`'s row carries, as the table asks for them.
    private static func writers(
        _ pane: PanelViewController,
        grabbing name: String
    ) -> [any NSPasteboardWriting]? {
        let index = pane.panel.displayedEntries.firstIndex { $0.name == name } ?? -1
        return pane.fileTable(FileTableView(), dragWritersFromRow: pane.row(forEntryIndex: index))
    }

    private static func promisedNames(_ writers: [any NSPasteboardWriting]?) -> [String] {
        (writers ?? []).compactMap { ($0 as? RemoteFilePromiseProvider)?.entry?.name }
    }

    @Test("a grab on a marked row carries the whole marked set, each server row as a promise")
    func markedGrabCarriesTheSet() {
        let pane = Self.pane(marked: ["a.txt", "c.txt"])
        let writers = Self.writers(pane, grabbing: "a.txt")
        #expect(writers?.count == 2)
        #expect(Self.promisedNames(writers) == ["a.txt", "c.txt"])
        // Whichever marked row is grabbed, the set is the same and in display order.
        #expect(Self.promisedNames(Self.writers(pane, grabbing: "c.txt")) == ["a.txt", "c.txt"])
    }

    @Test("a grab on an unmarked row drags that row alone")
    func unmarkedGrabDragsItself() {
        let pane = Self.pane(marked: ["a.txt", "c.txt"])
        #expect(Self.writers(pane, grabbing: "b.txt") == nil)
    }

    @Test("one marked row is a one-row drag, left to AppKit's own item")
    func singleMarkIsLeftAlone() {
        let pane = Self.pane(marked: ["a.txt"])
        #expect(Self.writers(pane, grabbing: "a.txt") == nil)
    }

    @Test("the table builds one item per writer at the grabbed frame, with the picture on the first")
    func itemsShareTheGrabbedFrame() throws {
        let frame = NSRect(x: 0, y: 40, width: 300, height: 20)
        let grabbed = NSDraggingItem(pasteboardWriter: NSPasteboardItem())
        grabbed.setDraggingFrame(frame, contents: NSImage(size: NSSize(width: 10, height: 10)))
        let writers = [NSPasteboardItem(), NSPasteboardItem(), NSPasteboardItem()]

        let items = FileTableView.draggingItems(for: writers, replacing: grabbed)

        #expect(items.count == 3)
        #expect(items.map(\.draggingFrame) == [frame, frame, frame])
        for (item, writer) in zip(items, writers) {
            // `ObjectIdentifier`, not `===`: `#expect(x as AnyObject === writer)` crashes SILGen.
            #expect(ObjectIdentifier(item.item as AnyObject) == ObjectIdentifier(writer))
        }
        let first = try #require(items.first?.imageComponents)
        #expect(!first.isEmpty)
        #expect(items.dropFirst().allSatisfy { ($0.imageComponents ?? []).isEmpty })
    }
}
