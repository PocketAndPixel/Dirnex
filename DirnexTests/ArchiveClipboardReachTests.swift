import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌘C, ⌘V and drag on a row that lives **inside an archive** (PLAN.md §M23 Slice 5).
///
/// The gap this closes is one gesture short of the rest of the milestone: the payload could always
/// name an archive member, and what was missing was a reader that knew to route one to an
/// *extraction* rather than to the copy queue — `CopyEngine` takes one backend for both ends and the
/// archive backend has no `copyFile`, so a member handed straight to the queue fails there, long
/// after the gesture. So Slice 2 wrote nothing to the board at all, and ⌘C inside an archive stayed
/// gray while F5 out of the same rows worked.
///
/// The end-to-end case at the bottom is what separates "the routing decision is right" from "the
/// bytes arrive": it packs a real zip with `bsdtar` and drives the real `resolveTransferSources`,
/// so the split, the extraction, the `stat` back into local entries and the temp directory are all
/// the shipped ones.
@MainActor
@Suite("Archive clipboard reach")
struct ArchiveClipboardReachTests {
    private static let archiveID = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
    private static let otherArchiveID = VFSBackendID.archive(forArchiveAt: "/tmp/other.zip")
    private static let remoteID = VFSBackendID("sftp://user@host")

    private func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 12,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 5
        )
    }

    private func member(_ inner: String, in archive: VFSBackendID = archiveID) -> FileEntry {
        entry(VFSPath(backend: archive, path: inner))
    }

    private func pane(
        backend: any VFSBackend,
        at path: VFSPath,
        capabilities: VFSCapabilities = [.read, .write],
        rows: [FileEntry] = []
    ) -> PanelViewController {
        let pane = PanelViewController(
            backend: backend, restoration: nil, defaultPath: path, restorationKey: nil
        )
        if !rows.isEmpty {
            pane.panel.setModel(
                DirectoryModel(listing: DirectoryListing(path: path, entries: rows))
            )
            pane.panel.moveCursor(to: 0)
        }
        _ = capabilities
        return pane
    }

    // MARK: - The split every route reads

    @Test("a member is routed to its archive and everything else goes straight to the queue")
    func splitsMembersFromDirectSources() {
        let split = ArchiveTransferSources([
            entry(.local("/tmp/a.txt")),
            member("/docs/x.md"),
            entry(VFSPath(backend: Self.remoteID, path: "/srv/b.bin"))
        ])

        #expect(split.direct.map(\.name) == ["a.txt", "b.bin"])
        #expect(split.groups.count == 1)
        #expect(split.groups[0].archivePath == "/tmp/pkg.zip")
        #expect(split.groups[0].members.map(\.name) == ["x.md"])
        #expect(split.needsExtraction)
    }

    @Test("two archives are two groups, in the order their rows arrived")
    func groupsPerArchiveInRowOrder() {
        // Reachable from a results tab: ⌥F7 can walk archives, so one search can land hits from
        // several. Dropping all but the first would be the quiet direction — a paste that copies
        // some of what was marked and reports success.
        let split = ArchiveTransferSources([
            member("/b.txt", in: Self.otherArchiveID),
            member("/a.txt"),
            member("/c.txt", in: Self.otherArchiveID)
        ])

        #expect(split.direct.isEmpty)
        #expect(split.groups.map(\.archivePath) == ["/tmp/other.zip", "/tmp/pkg.zip"])
        #expect(split.groups[0].members.map(\.name) == ["b.txt", "c.txt"])
        #expect(split.groups[1].members.map(\.name) == ["a.txt"])
    }

    @Test("an ordinary selection needs no extraction at all")
    func plainSourcesNeedNoExtraction() {
        let split = ArchiveTransferSources([entry(.local("/tmp/a.txt"))])
        #expect(!split.needsExtraction)
        #expect(split.groups.isEmpty)
        #expect(split.direct.count == 1)
    }

    // MARK: - ⌘C

    @Test("⌘C inside an archive now has something to copy — the gesture Slice 2 left gray")
    func copyReachesAnArchiveMember() {
        let pane = pane(
            backend: CompositeBackend(local: LocalBackend()),
            at: VFSPath(backend: Self.archiveID, path: "/docs"),
            rows: [member("/docs/x.md")]
        )

        #expect(pane.canCopyToClipboard)
        #expect(pane.clipboardTargets().map(\.name) == ["x.md"])
    }

    @Test("a mixed results tab now copies every row, archive hits included")
    func copyCarriesEveryRowOfAMixedTab() {
        // Slice 2's version of this test expected the archive hit to be filtered out; that was the
        // shape of the gap, not a rule — a search inside an archive lands its hits beside local and
        // remote ones and one ⌘C has to carry all three.
        let rows = [
            entry(.local("/tmp/hit.txt")),
            member("/inside.txt"),
            entry(VFSPath(backend: Self.remoteID, path: "/remote.bin"))
        ]
        let pane = pane(
            backend: CompositeBackend(local: LocalBackend()),
            at: VFSPath(backend: .search, path: "/results"),
            rows: rows
        )
        pane.panel.selectAll()

        #expect(pane.clipboardTargets().map(\.name) == ["hit.txt", "inside.txt", "remote.bin"])
    }

    @Test("the board carries the member's location and no file URL, which it has none of")
    func boardCarriesTheMember() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.archive-member"))
        board.clearContents()
        #expect(PanelPasteboard.write([member("/docs/x.md")], to: board))

        let item = try #require(board.pasteboardItems?.first)
        #expect(item.data(forType: PanelPasteboard.locationsType) != nil)
        // Writing a `file://` here would name a path on this Mac that does not exist — which is
        // exactly why Slice 2 refused the row rather than inventing one.
        #expect(item.string(forType: .fileURL) == nil)

        let payloads = PanelPasteboard.payloads(in: board)
        #expect(payloads.map(\.path.backend) == [Self.archiveID])
        #expect(payloads.first?.path.path == "/docs/x.md")
    }

    // MARK: - Drop

    @Test("an archive member can be dropped into a folder on disk")
    func memberDropsIntoALocalFolder() throws {
        // Before this slice the *board* was empty — `PanelPasteboard.write` refused the row — so
        // `dropPlan` answered `nil` and the pane showed "no drop" with nothing to say why.
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.archive-drop"))
        board.clearContents()
        #expect(PanelPasteboard.write([member("/docs/x.md")], to: board))

        let pane = pane(backend: CompositeBackend(local: LocalBackend()), at: .local("/tmp/dest"))
        let plan = try #require(pane.dropPlan(
            StubDraggingInfo(board: board, mask: [.copy, .move]), row: -1, dropOperation: .above
        ))
        #expect(plan.destination == .local("/tmp/dest"))
        // Never a move: there is nothing to remove from a read-only container, which is why F6 out
        // of an archive does not exist either (`TransferAdmission.allowsMove`).
        #expect(plan.kind == .copy)
        guard case let .locations(entries) = plan.sources else {
            Issue.record("a Dirnex drag must arrive as locations, not as URLs")
            return
        }
        #expect(entries.map(\.path.backend) == [Self.archiveID])
    }

    @Test("holding ⌘ over an archive member still badges — and performs — a copy")
    func forcedMoveOverAMemberStillCopies() throws {
        // The only case where the archive rule changes a drop's answer, and the one a headless test
        // could not reach until `dropPlan` took its modifiers: every *unmodified* archive drop is
        // already a backend crossing, so it copies whether or not the rule is there. What the badge
        // says is what the user is promised — `validateDrop` returns `plan.operation`.
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.archive-forced"))
        board.clearContents()
        #expect(PanelPasteboard.write([member("/docs/x.md")], to: board))

        let pane = pane(backend: CompositeBackend(local: LocalBackend()), at: .local("/tmp/dest"))
        let plan = try #require(pane.dropPlan(
            StubDraggingInfo(board: board, mask: [.copy, .move]),
            row: -1,
            dropOperation: .above,
            modifiers: .command
        ))
        #expect(plan.kind == .copy)
        #expect(plan.operation == .copy)
    }

    @Test("holding ⌘ over an ordinary local row still moves — the rule stays narrow")
    func forcedMoveOverALocalRowStillMoves() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("com.dirnex.tests.local-forced"))
        board.clearContents()
        #expect(PanelPasteboard.write([entry(.local("/tmp/src/a.txt"))], to: board))

        let pane = pane(backend: CompositeBackend(local: LocalBackend()), at: .local("/tmp/dest"))
        let plan = try #require(pane.dropPlan(
            StubDraggingInfo(board: board, mask: [.copy, .move]),
            row: -1,
            dropOperation: .above,
            modifiers: .command
        ))
        #expect(plan.kind == .move)
    }

    // MARK: - F5's own route is unchanged

    @Test("F5 still refuses a selection spanning two archives — one extraction, one destination")
    func f5StillTakesOneArchiveOnly() {
        let pane = pane(
            backend: CompositeBackend(local: LocalBackend()),
            at: VFSPath(backend: .search, path: "/results")
        )
        #expect(pane.extractionArchivePath(for: [
            member("/a.txt"), member("/b.txt", in: Self.otherArchiveID)
        ]) == nil)
        // …and still answers for one, which is what a search inside a single archive produces.
        #expect(pane.extractionArchivePath(for: [member("/a.txt")]) == "/tmp/pkg.zip")
        // A local row mixed in is not an extraction either: F5's destination and marks come from
        // the panes, so there is one of everything.
        #expect(pane.extractionArchivePath(for: [
            member("/a.txt"), entry(.local("/tmp/x.txt"))
        ]) == nil)
    }

    // MARK: - End to end, against a real archive on disk

    @Test("pasting a member resolves to a real file on disk holding the archived bytes")
    func resolvesAMemberIntoRealBytes() async throws {
        let fixture = try ZipFixture(entries: ["one.txt": "first", "two.txt": "second"])
        defer { fixture.remove() }

        let archive = VFSBackendID.archive(forArchiveAt: fixture.path)
        let pane = pane(backend: CompositeBackend(local: LocalBackend()), at: .local("/tmp"))

        let resolved = Resolved()
        pane.resolveTransferSources(
            .locations([entry(VFSPath(backend: archive, path: "/one.txt"))]),
            then: { resolved.value = $0 }
        )
        let sources = try #require(await resolved.settle(), "the extraction never reported back")

        // Real local files, which is the whole point: the queue can copy these and could not copy
        // the rows they came from.
        #expect(sources.count == 1)
        let source = try #require(sources.first)
        #expect(source.path.backend == .local)
        #expect(source.name == "one.txt")
        #expect(try String(contentsOfFile: source.path.path, encoding: .utf8) == "first")
        // The sibling stays in the archive — the member filter is the shipped one.
        let sibling = (source.path.path as NSString).deletingLastPathComponent + "/two.txt"
        #expect(!FileManager.default.fileExists(atPath: sibling))
        try? FileManager.default.removeItem(
            atPath: (source.path.path as NSString).deletingLastPathComponent
        )
    }

    @Test("a mixed paste keeps its ordinary sources beside the extracted one")
    func resolvesAMixedSetWholesale() async throws {
        let fixture = try ZipFixture(entries: ["one.txt": "first"])
        defer { fixture.remove() }
        let loose = fixture.directory.appendingPathComponent("loose.txt")
        try "loose".write(to: loose, atomically: true, encoding: .utf8)

        let archive = VFSBackendID.archive(forArchiveAt: fixture.path)
        let pane = pane(backend: CompositeBackend(local: LocalBackend()), at: .local("/tmp"))

        let resolved = Resolved()
        pane.resolveTransferSources(
            .fileURLs([loose]),
            then: { resolved.value = $0 }
        )
        let plain = try #require(await resolved.settle())
        #expect(plain.map(\.name) == ["loose.txt"])

        let both = Resolved()
        pane.resolveTransferSources(
            .locations([
                entry(.local(loose.path)),
                entry(VFSPath(backend: archive, path: "/one.txt"))
            ]),
            then: { both.value = $0 }
        )
        let sources = try #require(await both.settle())
        // Both arrive, and the extracted one is a real file — a mixed selection that silently lost
        // half of itself is the failure the split exists to prevent.
        #expect(sources.map(\.name).sorted() == ["loose.txt", "one.txt"])
        #expect(sources.allSatisfy { $0.path.backend == .local })
    }

    /// Somewhere for an escaping main-actor continuation to land, polled rather than waited on: a
    /// run-loop spin drives layout but never lets a detached read's continuation resume, so a
    /// view-shaped wait would read this as empty (docs/NOTES.md ▸ Testing).
    @MainActor
    private final class Resolved {
        var value: [FileEntry]?

        func settle() async -> [FileEntry]? {
            for _ in 0..<200 {
                if let value { return value }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return value
        }
    }

    /// A real, unencrypted zip packed by `bsdtar` — so the extraction under test is the shipped one
    /// and asks no passphrase, which would need a sheet nobody is here to answer.
    private final class ZipFixture {
        let directory: URL
        let path: String

        init(entries: [String: String]) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveClipboardReach-\(UUID().uuidString)")
            let staging = directory.appendingPathComponent("staging", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (name, contents) in entries {
                try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
            }
            path = directory.appendingPathComponent("pkg.zip").path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-c", "--format", "zip", "-f", path, "-C", staging.path]
                + entries.keys.sorted()
            try process.run()
            process.waitUntilExit()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
