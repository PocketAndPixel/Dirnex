import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Synchronize sheet comparing by contents when the contents are not on this disk
/// (PLAN.md §M25 Slice 5d).
///
/// Four claims, and none of them is about bytes: which pairs the sheet asks to have fetched, that
/// it asks **once** rather than walking again, that a declined download leaves the comparison it
/// was showing, and that what is finally read is the *stand-in* for each row rather than the row's
/// own path. The byte reading itself is `ByteComparator`'s and is covered in the core.
/// Every wait in this file is a wait **for** something, so it is free to be generous — and it has to
/// be: with a live SFTP server configured the sibling live suites hold the main actor for seconds at
/// a time, and every predicate here is satisfied on it. Measured 2026-08-29, the shared 10 s default
/// expired in 2 full runs of 6 on work that had already been done (docs/NOTES.md ▸ Testing).
private let syncScanBudget = Duration.seconds(30)

/// Outside the suite, which is `@MainActor`: the fixture builds its entries in a `nonisolated`
/// initializer and the backend reads them off the `BlockingWork` thread.
private let syncTestServer = SFTPLocation(host: "example.test", username: "oleg")

@Suite("Sync sheet: comparing by contents")
@MainActor
struct SyncContentScanTests {
    /// A local left side that is **really on disk** and a server's right that is not, with three
    /// same-named pairs: one whose sizes match (a candidate), one whose sizes do not, and one folder
    /// holding a second candidate.
    ///
    /// The left files are real because ``DirnexCore/MaterializedPaths`` answers for a local row with
    /// its *own* path — there is no copy anywhere for it to be holding, which is what keeps an
    /// all-local run from needing a map at all. So a content scan reads the left side where it lives
    /// and the right side through its stand-in, in the same pass.
    final class Fixture {
        let backend = CountingSyncBackend()
        let root: URL
        let left: VFSPath
        let right = VFSPath(backend: .sftp(syncTestServer), path: "/right")

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dirnex-sync-content-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("docs"),
                withIntermediateDirectories: true
            )
            try Data("aaaaa".utf8).write(to: root.appendingPathComponent("pair.txt"))
            try Data("a longer body".utf8).write(to: root.appendingPathComponent("sizes-differ.txt"))
            try Data("matched".utf8).write(to: root.appendingPathComponent("docs/note.md"))
            left = .local(root.path)

            backend.tree = [
                root.path: [
                    Self.file(root.path + "/pair.txt", 5),
                    Self.file(root.path + "/sizes-differ.txt", 13),
                    Self.folder(root.path + "/docs")
                ],
                "/right": [
                    Self.file("/right/pair.txt", 5, backend: .sftp(syncTestServer)),
                    Self.file("/right/sizes-differ.txt", 4, backend: .sftp(syncTestServer)),
                    Self.folder("/right/docs", backend: .sftp(syncTestServer))
                ],
                root.path + "/docs": [Self.file(root.path + "/docs/note.md", 7)],
                "/right/docs": [Self.file("/right/docs/note.md", 7, backend: .sftp(syncTestServer))]
            ]
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        static func file(
            _ path: String,
            _ size: Int64,
            backend: VFSBackendID = .local
        ) -> FileEntry {
            entry(path, kind: .file, size: size, backend: backend)
        }

        static func folder(_ path: String, backend: VFSBackendID = .local) -> FileEntry {
            entry(path, kind: .directory, size: 96, backend: backend)
        }

        private static func entry(
            _ path: String,
            kind: FileEntry.Kind,
            size: Int64,
            backend: VFSBackendID
        ) -> FileEntry {
            let vfs = VFSPath(backend: backend, path: path)
            return FileEntry(
                path: vfs,
                name: vfs.lastComponent,
                kind: kind,
                byteSize: size,
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                isHidden: false,
                permissions: 0o644,
                inode: 1
            )
        }
    }

    private static func sheet(_ fixture: Fixture) -> SyncDirectoriesController {
        let controller = SyncDirectoriesController(
            leftDir: fixture.left,
            rightDir: fixture.right,
            backend: fixture.backend,
            comparisons: SyncComparison.available(
                between: fixture.left.backend,
                and: fixture.right.backend
            ),
            directions: [.leftToRight]
        )
        controller.loadViewIfNeeded()
        return controller
    }

    private static func pickContents(_ sheet: SyncDirectoriesController) {
        let index = sheet.comparisons.firstIndex(of: .content) ?? 0
        sheet.comparisonControl.selectedSegment = index
        sheet.comparisonChanged(sheet.comparisonControl)
    }

    // MARK: - What it asks to have fetched

    /// The set handed to the panel is both sides of every pair whose bytes decide the answer, and
    /// nothing else: not the folder, not the pair a size mismatch already settled.
    ///
    /// It is the whole economy of the slice — the confirmation the user reads names this set, so a
    /// set that over-counted would ask for a download nobody needs and one that under-counted would
    /// throw mid-scan over a file sitting in front of them.
    @Test("only the same-size pairs are sent to be fetched, both sides of each")
    func onlyCandidatePairsAreFetched() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sheet = Self.sheet(fixture)
        var asked: [[FileEntry]] = []
        sheet.onPrepareContents = { entries, answer in
            asked.append(entries)
            answer(MaterializedPaths())
        }
        try await settleUntil(within: syncScanBudget) { !sheet.isScanning }

        Self.pickContents(sheet)
        try await settleUntil(within: syncScanBudget) { asked.count == 1 }

        let names = try #require(asked.first).map { "\($0.path.backend == .local ? "L" : "R"):\($0.name)" }
        #expect(names.sorted() == ["L:note.md", "L:pair.txt", "R:note.md", "R:pair.txt"])
    }

    /// The walk happens once and every comparison is derived from it — over a server each of those
    /// listings is a connection, or a billed request, for rows nothing has moved.
    @Test("switching the comparison re-derives rather than reading the folders again")
    func switchingComparisonsCostsNoListing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sheet = Self.sheet(fixture)
        sheet.onPrepareContents = { _, answer in answer(MaterializedPaths()) }
        try await settleUntil(within: syncScanBudget) { !sheet.isScanning }
        let afterFirstScan = fixture.backend.listCount
        #expect(afterFirstScan > 0, "the sheet has to walk once")

        // Wait for each switch to *finish*, not merely to be requested. `comparison` is assigned
        // synchronously on the way in, so a build that walked again would satisfy a wait on it long
        // before the walk landed and the count would be read too early — a control that fires on
        // nothing (docs/NOTES.md ▸ Testing).
        Self.pickContents(sheet)
        try await settleUntil(within: syncScanBudget) { sheet.comparison == .content && !sheet.isScanning }
        sheet.comparisonControl.selectedSegment = 0
        sheet.comparisonChanged(sheet.comparisonControl)
        try await settleUntil(within: syncScanBudget) { sheet.comparison == .size && !sheet.isScanning }

        #expect(fixture.backend.listCount == afterFirstScan)
    }

    // MARK: - When the download does not happen

    /// Declining the download is an ordinary answer, not a failure: the sheet goes back to the
    /// comparison it was showing, rows and picker together. Left as `.content` with no rows it
    /// would be a sheet claiming a comparison it never ran.
    @Test("a declined download leaves the comparison the sheet was showing")
    func aDeclinedDownloadRevertsTheComparison() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sheet = Self.sheet(fixture)
        sheet.onPrepareContents = { _, answer in answer(nil) }
        try await settleUntil(within: syncScanBudget) { !sheet.isScanning }
        let before = sheet.rows.map(\.entry.relativePath)

        Self.pickContents(sheet)
        try await settleUntil(within: syncScanBudget) { !sheet.isScanning && !sheet.isDownloadingContents }

        #expect(sheet.comparison == .size)
        #expect(sheet.comparisonControl.selectedSegment == 0)
        #expect(sheet.rows.map(\.entry.relativePath) == before)
        #expect(sheet.scanError == nil, "declining a download is an answer, not a failure")
    }

    // MARK: - What the bytes are read through

    /// The map is what the comparison reads, and the rows' own paths are not — which is M24's
    /// structural rule arriving at the last engine that needed it. `/right/pair.txt` is on a server
    /// and has no bytes here at all; what decides the row is the copy that came down.
    ///
    /// Two stand-ins with **different** bytes, so a build that read the rows' own paths cannot
    /// accidentally agree: it would throw on a `sftp://` path instead.
    @Test("the comparison reads each row's stand-in, not the row's own path")
    func theComparisonReadsTheStandIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // What the fetch would have brought down: the right side's two candidates, one differing
        // from its local twin and one identical to it.
        let stagedPair = fixture.root.appendingPathComponent("staged-pair")
        let stagedNote = fixture.root.appendingPathComponent("staged-note")
        try Data("bbbbb".utf8).write(to: stagedPair)
        try Data("matched".utf8).write(to: stagedNote)

        let sheet = Self.sheet(fixture)
        sheet.onPrepareContents = { _, answer in
            answer(MaterializedPaths([
                VFSPath(backend: .sftp(syncTestServer), path: "/right/pair.txt"): stagedPair.path,
                VFSPath(backend: .sftp(syncTestServer), path: "/right/docs/note.md"): stagedNote.path
            ]))
        }
        try await settleUntil(within: syncScanBudget) { !sheet.isScanning }

        Self.pickContents(sheet)
        try await settleUntil(within: syncScanBudget) { sheet.comparison == .content && !sheet.isScanning }

        #expect(sheet.scanError == nil)
        // `pair.txt` matched on size and differs in its bytes, so only reading them finds it;
        // `docs/note.md` matched on both and is gone from the list. The size mismatch is still a
        // row and cost no read.
        #expect(sheet.rows.map(\.entry.relativePath).sorted() == ["pair.txt", "sizes-differ.txt"])
        // Neither side's clock can be believed, so a content difference is still never ranked.
        let pair = try #require(sheet.rows.first { $0.entry.relativePath == "pair.txt" })
        #expect(pair.entry.status == .differ)
    }
}

/// The panel's half of the same gesture: what it hands the funnel, and what it answers the sheet
/// when the funnel gives up.
///
/// Driven through `prepareSyncContents` rather than through the sheet, because the sheet's fake
/// stands exactly where this code is — a suite that supplies its own `onPrepareContents` proves
/// nothing about the one the panel installs. The **cancelled** report is the exit worth driving
/// here: it is an abandonment with no dialog in it at all, so the claim can be made without
/// presenting a modal in a test host (docs/NOTES.md ▸ Testing).
@Suite("Sync sheet: what the panel hands back")
@MainActor
struct SyncContentPreparationTests {
    /// The success path: every remote row is fetched, and what comes back names the copy that
    /// landed rather than the object on the server — which is the whole point of the map.
    @Test("a fetched set answers with a stand-in for every row that is not on this disk")
    func aFetchedSetAnswersWithItsStandIns() async throws {
        let (pane, host) = hostedPane()
        let rows = [Handoff.remote("/srv/a.bin"), Handoff.remote("/srv/b.bin")]
        let copies = try rows.map { try Handoff.temporaryFile(named: $0.name) }
        host.materializeReport = Handoff.report(landing: Array(zip(rows, copies)))
        host.remoteFileCache.adopt(zip(rows, copies).map { row, copy in
            MaterializedFile(
                source: row.path,
                localPath: copy.path,
                revision: RemoteFileRevision(row)
            )
        })

        var answered: MaterializedPaths?
        var answers = 0
        pane.prepareSyncContents(rows) { paths in
            answered = paths
            answers += 1
        }
        try await settleUntil(within: syncScanBudget) { answers == 1 }

        let map = try #require(answered)
        #expect(map.localPath(for: rows[0].path)?.path == copies[0].path)
        #expect(map.localPath(for: rows[1].path)?.path == copies[1].path)
    }

    /// Every closure the sheet needs is installed, and `onPrepareContents` is the one worth naming:
    /// without it a content comparison over a remote pair falls back to an empty map and fails as
    /// *"The folders couldn't be compared"* — a sentence about the folders over a missing line of
    /// wiring, which is the failure M22's `subtreeListing` and M25 Slice 5b's `metadataTally` each
    /// shipped with and neither suite could see.
    @Test("the panel hands the sheet every closure it needs")
    func theSheetIsFullyWired() {
        let (pane, host) = hostedPane()
        let sheet = pane.makeSyncController(
            leftDir: .local("/tmp/left"),
            rightDir: VFSPath(backend: Handoff.remoteID, path: "/srv"),
            directions: [.leftToRight]
        )
        #expect(sheet.onApply != nil)
        #expect(sheet.onCompare != nil)
        #expect(sheet.onPrepareContents != nil)
        #expect(host.enqueued.isEmpty, "building the sheet starts no work")
    }

    /// A stopped transfer is the user's own answer and the queue bar has already shown it, so
    /// nothing is reported — but the sheet is *waiting*, and something has to tell it to stop.
    /// Without this it says "Downloading files to compare…" for the rest of the session.
    @Test("a stopped transfer answers the sheet rather than leaving it waiting")
    func aStoppedTransferAnswersNothing() async throws {
        let (pane, host) = hostedPane()
        let rows = [Handoff.remote("/srv/a.bin")]
        host.materializeReport = Handoff.report(cancelled: true)

        var answers: [MaterializedPaths?] = []
        pane.prepareSyncContents(rows) { answers.append($0) }
        try await settleUntil(within: syncScanBudget) { !answers.isEmpty }

        #expect(answers.count == 1, "answered exactly once, whichever way it ended")
        #expect(answers.first ?? MaterializedPaths() == nil)
    }
}

/// Lists a fixed tree and counts how many times it was asked — the observable behind "the walk
/// happens once". Offers no subtree shortcut, so the walk is one listing per directory pair and the
/// count is a number a test can reason about.
final class CountingSyncBackend: VFSBackend, @unchecked Sendable {
    var tree: [String: [FileEntry]] = [:]
    private let lock = NSLock()
    private var lists = 0

    var listCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lists
    }

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read, .write] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        lists += 1
        lock.unlock()
        return tree[path.path] ?? []
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        for entries in tree.values {
            if let match = entries.first(where: { $0.path.path == path.path }) { return match }
        }
        throw VFSError.notFound(path)
    }
}
