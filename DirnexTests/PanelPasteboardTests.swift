import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What Dirnex puts on the pasteboard and what it makes of what it is handed (PLAN.md §M23 Slice 2).
///
/// Every test writes to a **named** board rather than `.general`: this suite runs on the developer's
/// own Mac, and clobbering their clipboard to check a `Bool` is not a cost a test gets to impose.
///
/// The cases are chosen around the two ways this fails quietly. A **multi-row** board is read wrong
/// by the obvious implementation (a board-level `data(forType:)` returns only the first item), and a
/// **mixed** board is read wrong by preferring the file URLs (they silently omit every remote row),
/// so both are pinned by *count* — which is the only thing that separates a correct read from a
/// plausible one.
@Suite("PanelPasteboard")
struct PanelPasteboardTests {
    private static let remoteID = VFSBackendID("sftp://user@host")

    private func board(_ name: String) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.\(name)"))
        board.clearContents()
        return board
    }

    private func entry(
        _ path: VFSPath,
        kind: FileEntry.Kind = .file,
        size: Int64 = 64
    ) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: size,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 7
        )
    }

    private func local(_ path: String) -> FileEntry { entry(.local(path)) }
    private func remote(_ path: String) -> FileEntry {
        entry(VFSPath(backend: Self.remoteID, path: path))
    }

    // MARK: - Writing

    @Test("a local row carries both carriers, so Finder still sees an ordinary file")
    func localRowCarriesBoth() throws {
        let board = board("local")
        #expect(PanelPasteboard.write([local("/tmp/a.txt")], to: board))

        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: PanelPasteboard.locationsType) != nil)
        #expect(item.string(forType: .fileURL) != nil)
        #expect(PanelPasteboard.fileURLs(in: board).map(\.lastPathComponent) == ["a.txt"])
    }

    @Test("a remote row carries the payload and no file URL — the gap M23 exists to close")
    func remoteRowCarriesThePayloadOnly() throws {
        let board = board("remote")
        #expect(PanelPasteboard.write([remote("/srv/report.pdf")], to: board))

        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: PanelPasteboard.locationsType) != nil)
        // No bogus `file://` path: writing one is what the pre-M23 code refused to do, correctly.
        #expect(item.string(forType: .fileURL) == nil)
        #expect(PanelPasteboard.fileURLs(in: board).isEmpty)

        let payloads = PanelPasteboard.payloads(in: board)
        #expect(payloads.count == 1)
        #expect(payloads.first?.path.backend == Self.remoteID)
    }

    @Test("every row of a multi-row write is readable, not just the first")
    func readsEveryItem() {
        // The trap: `board.data(forType:)` answers with item 0 alone, so a reader written that way
        // drops four of these five and reports success.
        let board = board("many")
        let rows = (0..<5).map { remote("/srv/file\($0).bin") }
        #expect(PanelPasteboard.write(rows, to: board))

        let payloads = PanelPasteboard.payloads(in: board)
        #expect(payloads.count == 5)
        #expect(payloads.map(\.name) == rows.map(\.name))
    }

    @Test("an empty selection leaves the board alone rather than clearing it")
    func writingNothingLeavesTheBoard() {
        let board = board("archive")
        #expect(PanelPasteboard.write([local("/tmp/kept.txt")], to: board))
        // Nothing writable at all: the previous contents stay, so a ⌘C with no target cannot
        // silently destroy a clipboard the user still wanted.
        #expect(!PanelPasteboard.write([], to: board))
        #expect(PanelPasteboard.fileURLs(in: board).map(\.lastPathComponent) == ["kept.txt"])
    }

    @Test("an archive member is carried too since Slice 5 — the reader knows to extract it")
    func carriesArchiveMembers() throws {
        // Slice 2 deliberately left this row off the board: the payload could name it, and nothing
        // that *read* one knew to route it to an extraction, so a paste would have failed inside
        // the queue. `PanelViewController.resolveTransferSources` is that reader.
        let member = entry(
            VFSPath(backend: .archive(forArchiveAt: "/tmp/pkg.zip"), path: "/docs/x.md")
        )
        let board = board("member")
        #expect(PanelPasteboard.write([member], to: board))

        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: PanelPasteboard.locationsType) != nil)
        #expect(item.string(forType: .fileURL) == nil)
        #expect(PanelPasteboard.payloads(in: board).first?.path.backend.isArchive == true)
    }

    @Test("a mixed selection keeps every row for Dirnex and the local subset for everyone else")
    func mixedSelectionSplitsCorrectly() throws {
        let board = board("mixed")
        let rows = [local("/tmp/x.txt"), remote("/srv/big.bin"), local("/tmp/y.txt")]
        #expect(PanelPasteboard.write(rows, to: board))

        // What another app receives: the two it can actually open.
        #expect(PanelPasteboard.fileURLs(in: board).map(\.lastPathComponent) == ["x.txt", "y.txt"])
        // What Dirnex receives: all three, in order.
        #expect(PanelPasteboard.payloads(in: board).map(\.name) == ["x.txt", "big.bin", "y.txt"])
    }

    // MARK: - Reading

    @Test("our own board resolves through the payload, so a mixed copy pastes every row")
    func prefersThePayloadOverTheURLs() throws {
        // The quiet failure this guards: reading the URLs off our *own* board is a different
        // answer, not a poorer one — it omits the remote row, so copying three files and pasting
        // two would report success.
        let board = board("prefer")
        #expect(PanelPasteboard.write(
            [local("/tmp/x.txt"), remote("/srv/big.bin"), local("/tmp/y.txt")], to: board
        ))

        let sources = try #require(PanelPasteboard.sources(in: board))
        guard case let .locations(entries) = sources else {
            Issue.record("expected the payload to win over the file URLs")
            return
        }
        #expect(entries.count == 3)
        #expect(entries.map(\.path.backend).contains(Self.remoteID))
    }

    @Test("a board from another app resolves as file URLs, which the caller still has to stat")
    func foreignBoardResolvesAsURLs() throws {
        let board = board("foreign")
        board.clearContents()
        // Finder's shape: URLs and nothing else.
        #expect(board.writeObjects([URL(fileURLWithPath: "/tmp/dropped.txt") as NSURL]))

        let sources = try #require(PanelPasteboard.sources(in: board))
        guard case let .fileURLs(urls) = sources else {
            Issue.record("a board with no payload must resolve as URLs")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["dropped.txt"])
    }

    @Test("an empty board offers nothing at all")
    func emptyBoardOffersNothing() {
        let board = board("empty")
        #expect(PanelPasteboard.sources(in: board) == nil)
        #expect(!PanelPasteboard.holdsSomethingToTransfer(board))
    }

    @Test("Paste stays enabled for both carriers, which is the whole point of asking for either")
    func enablementSeesBothCarriers() {
        // A remote-only board answers `canReadObject(forClasses: [NSURL.self])` → false (probed), so
        // the pre-M23 gate grayed Paste out after a ⌘C on a server — the case this milestone fixes.
        let remoteOnly = board("enable-remote")
        #expect(PanelPasteboard.write([remote("/srv/a.bin")], to: remoteOnly))
        #expect(!remoteOnly.canReadObject(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ))
        #expect(PanelPasteboard.holdsSomethingToTransfer(remoteOnly))

        // …and a board with no payload of ours must still enable it, or pasting from Finder breaks.
        let urlOnly = board("enable-url")
        urlOnly.clearContents()
        #expect(urlOnly.writeObjects([URL(fileURLWithPath: "/tmp/z.txt") as NSURL]))
        #expect(PanelPasteboard.payloads(in: urlOnly).isEmpty)
        #expect(PanelPasteboard.holdsSomethingToTransfer(urlOnly))
    }

    @Test("a foreign payload under our type name is refused rather than half-read")
    func refusesForeignPayload() {
        let board = board("junk")
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("not our json".utf8), forType: PanelPasteboard.locationsType)
        #expect(board.writeObjects([item]))

        #expect(PanelPasteboard.payloads(in: board).isEmpty)
        #expect(PanelPasteboard.sources(in: board) == nil)
        #expect(!PanelPasteboard.holdsSomethingToTransfer(board))
    }
}
