import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Adding into a browsed archive from every gesture that reaches it (PLAN.md §M36 Slice 1).
///
/// Until M36 the add read file URLs and nothing else: ⌘V of a row copied on a server did nothing,
/// ⌥⌘V was gray, a drop was refused, and F5 from a server pane handed `ArchiveWriter` the server's
/// paths as if they were this Mac's — which adds whatever local file sits at that spelling. The
/// gestures now share `beginArchiveAdd`, and these tests hold it to the two claims that matter: what
/// may land, and where the bytes come from.
///
/// The end-to-end cases rewrite a real `bsdtar` zip with a **scratch** undo store. Through a pane the
/// default store is `ArchiveUndoStorage.shared`, which in this target is the developer's own
/// Application Support, so the one test that goes through F5's own route stops at the fetch it
/// requests rather than rewriting anything.
@MainActor
@Suite("Archive add reach")
struct ArchiveAddReachTests {
    private static let remoteID = VFSBackendID("sftp://user@host")

    private func entry(_ path: VFSPath, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 32,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 9
        )
    }

    /// A pane over the real composite backend, with a host so the funnel's caches and fetch exist.
    /// Both are returned: `host` is `weak`, and dropping it measures the no-host path instead.
    private func pane(
        at path: VFSPath,
        rows: [FileEntry] = [],
        host: StubPanelHost = StubPanelHost()
    ) -> (PanelViewController, StubPanelHost) {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.host = host
        if !rows.isEmpty {
            pane.panel.setModel(DirectoryModel(listing: DirectoryListing(path: path, entries: rows)))
            pane.panel.moveCursor(to: 0)
        }
        return (pane, host)
    }

    private func drag(_ entries: [FileEntry], board name: String) -> StubDraggingInfo {
        let board = NSPasteboard(name: NSPasteboard.Name("app.dirnex.tests.archive-add.\(name)"))
        board.clearContents()
        _ = PanelPasteboard.write(entries, to: board)
        return StubDraggingInfo(board: board, mask: [.copy, .move])
    }

    // MARK: - A drop into an archive

    private static let archiveID = VFSBackendID.archive(forArchiveAt: "/tmp/m36/pkg.zip")

    @Test("a writable archive takes a drop from this Mac, as a copy — ⌘V's repack")
    func archiveTakesADrop() throws {
        let (pane, host) = pane(at: VFSPath(backend: Self.archiveID, path: "/docs"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/src/a.txt"))], board: "plain"), row: -1, dropOperation: .above
        ))
        #expect(plan.destination == VFSPath(backend: Self.archiveID, path: "/docs"))
        // A backend crossing is never one volume, so an unmodified drag copies.
        #expect(plan.kind == .copy)
        _ = host
    }

    @Test("holding ⌘ moves into it, which adds and then removes the original")
    func commandMovesIntoAnArchive() throws {
        let (pane, host) = pane(at: VFSPath(backend: Self.archiveID, path: "/"))
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/src/a.txt"))], board: "move"),
            row: -1, dropOperation: .above, modifiers: .command
        ))
        #expect(plan.kind == .move)
        _ = host
    }

    @Test("a drop on a folder row lands in that folder of the archive")
    func dropOnAFolderRowLandsInIt() throws {
        let folder = entry(VFSPath(backend: Self.archiveID, path: "/docs/sub"), kind: .directory)
        let (pane, host) = pane(at: VFSPath(backend: Self.archiveID, path: "/docs"), rows: [folder])
        let plan = try #require(pane.dropPlan(
            drag([entry(.local("/tmp/src/a.txt"))], board: "row"),
            row: pane.row(forEntryIndex: 0), dropOperation: .on
        ))
        #expect(plan.destination == folder.path)
        _ = host
    }

    /// The recursion the archive's own backend id hid: `proj/pkg.zip`'s contents carry the backend
    /// `archive:…`, so a backend compare said `proj` could not hold them.
    @Test("the folder holding the archive, and the archive itself, are no drop at all")
    func holdingFolderIsNoDrop() {
        let (pane, host) = pane(at: VFSPath(backend: Self.archiveID, path: "/"))
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/m36"), kind: .directory)], board: "holder"),
            row: -1, dropOperation: .above
        ) == nil)
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/m36/pkg.zip"))], board: "itself"),
            row: -1, dropOperation: .above
        ) == nil)
        // The control: a sibling of the archive is an ordinary drop.
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/m36/notes.txt"))], board: "sibling"),
            row: -1, dropOperation: .above
        ) != nil)
        _ = host
    }

    @Test("a nested archive takes no drop — its mount is a temp copy of a member")
    func nestedArchiveTakesNoDrop() {
        let nested = VFSBackendID.archive(forArchiveAt: "/tmp/m36/extracted/inner.zip")
        let (pane, host) = pane(at: VFSPath(backend: nested, path: "/"))
        host.nestedArchiveRegistry.record(
            mountOnDiskPath: "/tmp/m36/extracted/inner.zip",
            origin: VFSPath(backend: Self.archiveID, path: "/inner.zip")
        )
        #expect(pane.dropPlan(
            drag([entry(.local("/tmp/src/a.txt"))], board: "nested"), row: -1, dropOperation: .above
        ) == nil)
    }

    // MARK: - Where the bytes come from

    /// The bug the funnel exists to close, reproduced exactly: a local file at the very path the
    /// server's row names. Handing that path to `ArchiveWriter` added *this Mac's* bytes under the
    /// server's name; staging it adds the server's.
    @Test("a row on a server is downloaded first, and the archive gains the server's bytes")
    func serverRowIsStagedNotReadLocally() async throws {
        let fixture = try await ZipFixture.make(entries: ["kept.txt": "kept"])
        let sameSpelling = fixture.directory.appendingPathComponent("same.txt")
        try "this Mac's bytes".write(to: sameSpelling, atomically: true, encoding: .utf8)
        let staged = fixture.directory.appendingPathComponent("staged/same.txt")
        try FileManager.default.createDirectory(
            at: staged.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "the server's bytes".write(to: staged, atomically: true, encoding: .utf8)

        let remote = entry(VFSPath(backend: Self.remoteID, path: sameSpelling.path))
        let (pane, host) = pane(at: fixture.root)
        host.materializeReport = Self.report(staging: [(remote, staged)])

        pane.beginArchiveAdd(
            [remote], into: fixture.root, kind: .copy, originalsIn: nil, undo: fixture.undo
        )

        // Settled on the journal rather than on the archive: the rewrite lands off the main actor
        // and the record follows it there, so the archive alone can be read before the flow is over.
        guard await Self.finish(holding: [pane, host, fixture], until: {
            host.recordedUndo.count == 1
        }) else { return }
        #expect(try await fixture.member("same.txt") == "the server's bytes")
        #expect(host.materializedEntries.flatMap(\.self).map(\.path) == [remote.path])
        #expect(try await fixture.member("kept.txt") == "kept")
        fixture.remove()
    }

    @Test("a file on this Mac is added as it is, with nothing fetched")
    func localFileIsAddedDirectly() async throws {
        let fixture = try await ZipFixture.make(entries: ["kept.txt": "kept"])
        let loose = fixture.directory.appendingPathComponent("loose.txt")
        try "loose".write(to: loose, atomically: true, encoding: .utf8)

        let (pane, host) = pane(at: fixture.root)
        pane.beginArchiveAdd(
            [entry(.local(loose.path))], into: fixture.root, kind: .copy, originalsIn: nil,
            undo: fixture.undo
        )

        guard await Self.finish(holding: [pane, host, fixture], until: {
            host.recordedUndo.count == 1
        }) else { return }
        #expect(try await fixture.member("loose.txt") == "loose")
        #expect(host.materializedEntries.isEmpty)
        // A copy leaves the original where it was.
        #expect(FileManager.default.fileExists(atPath: loose.path))
        fixture.remove()
    }

    @Test("a member of another archive is extracted on the way in")
    func memberOfAnotherArchiveIsExtracted() async throws {
        let fixture = try await ZipFixture.make(entries: ["kept.txt": "kept"])
        let other = try await ZipFixture.make(entries: ["from-other.txt": "other bytes"])

        let (pane, host) = pane(at: fixture.root)
        let member = entry(VFSPath(backend: other.root.backend, path: "/from-other.txt"))
        pane.beginArchiveAdd(
            [member], into: fixture.root, kind: .copy, originalsIn: nil, undo: fixture.undo
        )

        guard await Self.finish(holding: [pane, host, fixture, other], until: {
            host.recordedUndo.count == 1
        }) else { return }
        #expect(try await fixture.member("from-other.txt") == "other bytes")
        fixture.remove()
        other.remove()
    }

    // MARK: - The routes into it

    /// F5's own route, stopped at the fetch: it reaches the funnel and asks for the server's bytes,
    /// where it used to rewrite the archive from the local path. Nothing is answered, so nothing is
    /// rewritten and the developer's undo store is never touched.
    @Test("F5 from a server pane into an archive asks for the server's bytes")
    func f5FromAServerPaneStages() async throws {
        let fixture = try await ZipFixture.make(entries: ["kept.txt": "kept"])
        let before = try Data(contentsOf: URL(fileURLWithPath: fixture.path))

        let host = StubPanelHost()
        host.materializeReport = nil
        let (archivePane, _) = pane(at: fixture.root, host: host)
        let remote = entry(VFSPath(backend: Self.remoteID, path: "/srv/report.txt"))
        let (serverPane, _) = pane(
            at: VFSPath(backend: Self.remoteID, path: "/srv"), rows: [remote], host: host
        )
        host.counterpart = archivePane

        serverPane.copyToOtherPane(nil)

        guard await Self.finish(holding: [archivePane, serverPane, host, fixture], until: {
            !host.materializedEntries.isEmpty
        }) else { return }
        #expect(host.materializedEntries.flatMap(\.self).map(\.path) == [remote.path])
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == before)
        fixture.remove()
    }

    /// ⌥⌘V and a ⌘-drag read the board through `addOffered`: an archive member falls out of a move,
    /// which has nothing to remove from a read-only container, and the rest still goes.
    @Test("a move into an archive drops a member and stages everything else")
    func moveDropsAMemberAndStagesTheRest() async throws {
        let fixture = try await ZipFixture.make(entries: ["kept.txt": "kept"])
        let other = try await ZipFixture.make(entries: ["elsewhere.txt": "elsewhere"])

        let host = StubPanelHost()
        host.materializeReport = nil
        let (archivePane, _) = pane(at: fixture.root, host: host)
        let remote = entry(VFSPath(backend: Self.remoteID, path: "/srv/report.txt"))
        let member = entry(VFSPath(backend: other.root.backend, path: "/elsewhere.txt"))

        archivePane.addOffered(.locations([member, remote]), into: fixture.root, kind: .move)

        // Members are extracted before the fetch is asked for, so once it has been the member's
        // fate is settled: it was never extracted, because it was never admitted.
        guard await Self.finish(holding: [archivePane, host, fixture, other], until: {
            !host.materializedEntries.isEmpty
        }) else { return }
        #expect(host.materializedEntries.flatMap(\.self).map(\.path) == [remote.path])
        #expect(host.archivePreviewCache.cachedURL(
            for: ArchiveMember(archivePath: other.path, innerPath: "/elsewhere.txt")
        ) == nil)
        fixture.remove()
        other.remove()
    }

    // MARK: - Waiting

    /// Everything an add that outlived its test still needs, kept for the rest of the run.
    private static var outlived: [AnyObject] = []

    /// Wait for an add to reach `isDone`, and if it outlives the wait, keep what it touches alive.
    ///
    /// Both halves were measured in a parallel run of the whole app suite (2026-11-08). The add hops
    /// on and off the main actor half a dozen times, and with two thousand tests sharing it the first
    /// hop waited 26 s, so the budget is generous. And an add still running when its test ends must
    /// not find its host or its archive gone: it then reports a failure, which with no window is an
    /// **app-modal alert** that stops the main actor and every suite after it until somebody clicks
    /// OK. So a test that gives up leaves the pane, the host and the fixtures where they are, and the
    /// add finishes against them quietly.
    private static func finish(
        holding parts: [AnyObject],
        until isDone: @MainActor () -> Bool
    ) async -> Bool {
        if await settle(within: .seconds(120), until: isDone) { return true }
        outlived.append(contentsOf: parts)
        Issue.record("the add did not finish in 120 s; its pane, host and archives are kept alive")
        return false
    }

    // MARK: - Fixtures

    private static func report(staging files: [(FileEntry, URL)]) -> OperationReport {
        OperationReport(
            completedItems: files.count,
            completedBytes: 32,
            skipped: [],
            failures: [],
            wasCancelled: false,
            materialized: files.map {
                MaterializedFile(
                    source: $0.0.path, localPath: $0.1.path, revision: RemoteFileRevision($0.0)
                )
            }
        )
    }

    /// Polled rather than awaited: the add runs through a `Task`, the passphrase funnel and a
    /// blocking rewrite, none of which hands a test anything to await (docs/NOTES.md ▸ Testing).
    private static func settle(
        within budget: Duration,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }
}

/// A real, unencrypted zip packed by `bsdtar`, beside a scratch undo store.
///
/// `bsdtar` runs through `BlockingWork`, never on the main actor: `Process.waitUntilExit()` spins a
/// run loop nested in the test's own main-actor job, which drains nothing the main actor is owed, so
/// a fixture waiting there held up every add in this suite and in the suites beside it.
@MainActor
private final class ZipFixture {
    let directory: URL
    let path: String
    let undo: @Sendable () -> ArchiveUndoStorage.Request

    var root: VFSPath { VFSPath(backend: .archive(forArchiveAt: path), path: "/") }

    private init(directory: URL) {
        self.directory = directory
        path = directory.appendingPathComponent("pkg.zip").path
        let store = ArchiveUndoStore(root: directory.appendingPathComponent("undo-store"))
        undo = { ArchiveUndoStorage.Request(store: store, live: []) }
    }

    static func make(entries: [String: String]) async throws -> ZipFixture {
        let fixture = ZipFixture(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveAddReach-\(UUID().uuidString)")
        )
        let staging = fixture.directory.appendingPathComponent("packing", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for (name, contents) in entries {
            try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
        }
        try await bsdtar(["-c", "--format", "zip", "-f", fixture.path, "-C", staging.path]
            + entries.keys.sorted())
        return fixture
    }

    /// The member's bytes as text, read back by `bsdtar` itself rather than by the app.
    func member(_ name: String) async throws -> String {
        String(bytes: try await Self.bsdtar(["-x", "-O", "-f", path, name]), encoding: .utf8) ?? ""
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    private static func bsdtar(_ arguments: [String]) async throws -> Data {
        try await BlockingWork.run { () -> Result<Data, any Error> in
            Result {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadNoSuchFile) }
                return data
            }
        }.get()
    }
}
