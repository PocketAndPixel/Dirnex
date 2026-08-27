import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Hashing rows that are not on this disk, from the gesture's side (PLAN.md §M24 Slice 4).
///
/// The transfer is not under test and neither is the hashing — `MaterializeRunner` and
/// `ChecksumRunner` own those and are tested in the core against real backends. What an app test can
/// see is the **hand-over**: which rows the gesture asked for, and what map it put on the job. That
/// map is the whole slice on this side, because it is what keeps the manifest naming `report.pdf`
/// while the bytes it hashed came out of a temp directory.
@MainActor
@Suite("Materializing a checksum run")
struct ChecksumMaterializeTests {
    private static let manifestText = "d41d8cd98f00b204e9800998ecf8427e  a.bin\n"

    private func manifest(_ pane: PanelViewController) -> VFSPath {
        pane.panel.path.appending("files.md5")
    }

    private func startCreate(
        _ pane: PanelViewController,
        sources: [FileEntry],
        manifest: VFSPath
    ) {
        pane.startChecksumCreate(sources: sources, manifest: manifest, algorithm: .md5)
    }

    // MARK: - Create

    /// The control that keeps everything else here from being bought at the price of the common
    /// case: a marked set of plain local files queues in the same turn, with nothing fetched and an
    /// **empty** map — which is what makes `MaterializedPaths` answer for them with their own paths.
    @Test("a local set is queued at once, with nothing fetched and no map")
    func localCreateCostsNothing() {
        let (pane, host) = hostedPane()
        let rows = [Handoff.local("/tmp/a.bin"), Handoff.local("/tmp/b.bin")]

        startCreate(pane, sources: rows, manifest: manifest(pane))

        #expect(host.materializedEntries.isEmpty)
        #expect(host.enqueued.count == 1)
        #expect(host.enqueued[0].materialized.isEmpty)
    }

    /// The slice itself: every remote row is fetched, and the job carries which local file stands
    /// for each of them. Without the map the engine would be handed the server's own paths and
    /// answer "not downloaded" for every row it had just downloaded.
    @Test("a remote set is fetched and the job carries a stand-in for every row")
    func remoteCreateCarriesTheMap() throws {
        let (pane, host) = hostedPane()
        let rows = [Handoff.remote("/srv/a.bin"), Handoff.remote("/srv/b.bin")]
        let copies = try rows.map { try Handoff.temporaryFile(named: $0.name) }
        host.materializeReport = Handoff.report(landing: Array(zip(rows, copies)))

        startCreate(pane, sources: rows, manifest: manifest(pane))

        #expect(host.materializedEntries.map { $0.map(\.path) } == [rows.map(\.path)])
        let queued = try #require(host.enqueued.first)
        #expect(queued.materialized.localPath(for: rows[0].path) == .local(copies[0].path))
        #expect(queued.materialized.localPath(for: rows[1].path) == .local(copies[1].path))
    }

    /// The map is built from what the window can *find*, never from the transfer's report — a row an
    /// earlier preview already downloaded is exactly as readable and is deliberately not re-fetched,
    /// so a map assembled from the report alone would report it as not downloaded.
    @Test("a row already cached is in the map even though nothing was fetched for it")
    func cachedRowsAreInTheMap() throws {
        let (pane, host) = hostedPane()
        let cached = Handoff.remote("/srv/a.bin")
        let fresh = Handoff.remote("/srv/b.bin")
        let cachedCopy = try Handoff.temporaryFile(named: "a.bin")
        let freshCopy = try Handoff.temporaryFile(named: "b.bin")
        // Put the first row in the cache the way an earlier gesture would have.
        host.remoteFileCache.adopt([
            MaterializedFile(
                source: cached.path,
                localPath: cachedCopy.path,
                revision: RemoteFileRevision(cached)
            )
        ])
        host.materializeReport = Handoff.report(landing: [(fresh, freshCopy)])

        startCreate(pane, sources: [cached, fresh], manifest: manifest(pane))

        // Only the uncached row was asked for…
        #expect(host.materializedEntries.map { $0.map(\.path) } == [[fresh.path]])
        // …and both are in the map.
        let queued = try #require(host.enqueued.first)
        #expect(queued.materialized.localPath(for: cached.path) == .local(cachedCopy.path))
        #expect(queued.materialized.localPath(for: fresh.path) == .local(freshCopy.path))
    }

    /// A set that only half arrived queues nothing at all. A manifest short of a file the user
    /// marked verifies clean ever after while saying nothing about the file it never looked at —
    /// the same false comfort `ChecksumEntryStatus.extra` exists to prevent, one step earlier.
    @Test("a set that only half arrived is not hashed")
    func aPartialSetIsNotQueued() throws {
        let hosted = windowedPane()
        let landed = Handoff.remote("/srv/a.bin")
        let lost = Handoff.remote("/srv/b.bin")
        let copy = try Handoff.temporaryFile(named: "a.bin")
        hosted.host.materializeReport = Handoff.report(landing: [(landed, copy)], failing: [lost])

        startCreate(hosted.pane, sources: [landed, lost], manifest: manifest(hosted.pane))

        #expect(hosted.host.enqueued.isEmpty)
        #expect(hosted.window.attachedSheet != nil)
    }

    // MARK: - Create's gate

    /// A folder that is not already here stands for an unknown number of objects in an unknown
    /// number of requests, which is exactly why `MaterializationPlan` names those rows rather than
    /// weighing them. The hand-off refuses one for the same reason; copying a tree over is F5's.
    @Test("a folder that is not on this disk is refused, and nothing is queued")
    func remoteFolderIsRefused() {
        let rows = [Handoff.remote("/srv/a.bin"), Handoff.remote("/srv/sub", kind: .directory)]
        let hosted = windowedPane(showing: rows)
        hosted.pane.panel.setSelection(Set(rows.map(\.path)))

        hosted.pane.createChecksumFile(nil)

        #expect(hosted.host.enqueued.isEmpty)
        #expect(hosted.host.materializedEntries.isEmpty)
        // **Which** sheet, not merely that one appeared: the create sheet is a sheet too, so
        // `attachedSheet != nil` alone passes against a build that refuses nothing — measured, and
        // it is why the button count is the assertion.
        #expect(sheetButtonCount(in: hosted.window) == 1)
    }

    /// The narrowness control for the line above: a **local** folder is still an ordinary thing to
    /// checksum, and the runner descends into it. Without this, "refuse a folder that is not here"
    /// would quietly become "refuse a folder".
    @Test("a local folder is not refused")
    func localFolderIsFine() {
        let rows = [Handoff.local("/tmp/a.bin"), Handoff.local("/tmp/sub", kind: .directory)]
        let (pane, _) = hostedPane(showing: rows)
        pane.panel.setSelection(Set(rows.map(\.path)))

        #expect(pane.materializationPlan(for: pane.selectionTargets()).pendingDirectories.isEmpty)
        #expect(pane.canCreateChecksumFile)
    }

    /// The manifest goes where its names resolve from, so what has to be writable is *that*
    /// directory — which for a bucket's objects is the bucket, and is an upload. A read-only one
    /// says no, and says it before the sheet rather than after the hashing.
    /// The selection sits **deeper than the pane**, which is what makes this a claim about the
    /// manifest's own directory rather than about the pane's: the two are the same folder in a flat
    /// listing and need not be in a tree, and asking the pane would answer "writable" about a folder
    /// the write never reaches.
    @Test("a read-only destination cannot take a manifest, even when the pane is writable")
    func readOnlyDestinationIsRefused() {
        let deeper = VFSPath.local("/tmp/sub")
        var backend = Handoff.StubBackend()
        backend.readOnlyPaths = [deeper]
        let row = Handoff.local("/tmp/sub/a.bin")
        let (pane, _) = hostedPane(showing: [row], backend: backend)
        pane.panel.setSelection([row.path])

        #expect(pane.checksumDirectory(for: [row]) == deeper)
        #expect(!pane.canCreateChecksumFile)
    }

    /// The narrowness control for the line above: a writable destination still says yes, so
    /// "ask the manifest's directory" cannot quietly become "always refuse".
    @Test("a writable destination can take a manifest")
    func writableDestinationIsAllowed() {
        let row = Handoff.local("/tmp/sub/a.bin")
        let (pane, _) = hostedPane(showing: [row])
        pane.panel.setSelection([row.path])

        #expect(pane.canCreateChecksumFile)
    }

    // MARK: - Verify

    /// A manifest on this disk names files on this disk — the walk is rooted at its own parent — so
    /// the ordinary case must reach the queue in one turn, with nothing fetched and no second
    /// directory walk. This is what keeps the two-phase gesture below off the common path.
    @Test("a local manifest is verified at once, with nothing fetched")
    func localVerifyCostsNothing() throws {
        let (pane, host) = hostedPane(showing: [Handoff.local("/tmp/files.md5")])

        pane.verifyChecksums(nil)

        #expect(host.materializedEntries.isEmpty)
        let queued = try #require(host.enqueued.first)
        #expect(queued.materialized.isEmpty)
        #expect(queued.kind == .checksum(.verify(manifest: .local("/tmp/files.md5"))))
    }

    /// **The two-phase gesture.** Nothing can know what else to fetch until the manifest has been
    /// read, so the manifest comes down first, its directory is walked, and the files it claims come
    /// down second — and the job carries one map holding both.
    @Test("a remote manifest is fetched, walked, and its claimed files fetched after it")
    func remoteVerifyIsTwoPhase() async throws {
        let root = VFSPath(backend: Handoff.remoteID, path: "/srv")
        let manifestRow = Handoff.remote("/srv/files.md5")
        let claimed = Handoff.remote("/srv/a.bin")
        var backend = Handoff.StubBackend()
        backend.listings = [root: [manifestRow, claimed]]

        let manifestCopy = try Handoff.temporaryFile(named: "files.md5")
        try Data(Self.manifestText.utf8).write(to: manifestCopy)
        let claimedCopy = try Handoff.temporaryFile(named: "a.bin")

        let (pane, host) = hostedPane(showing: [manifestRow], at: root, backend: backend)
        host.materializeReports = [
            Handoff.report(landing: [(manifestRow, manifestCopy)]),
            Handoff.report(landing: [(claimed, claimedCopy)])
        ]

        pane.verifyChecksums(nil)
        try await settleUntil { host.enqueued.isEmpty == false }

        #expect(host.materializedEntries.map { $0.map(\.path) } == [
            [manifestRow.path], [claimed.path]
        ])
        let queued = try #require(host.enqueued.first)
        #expect(queued.materialized.localPath(for: manifestRow.path) == .local(manifestCopy.path))
        #expect(queued.materialized.localPath(for: claimed.path) == .local(claimedCopy.path))
    }

    /// A manifest that cannot be read as one is the *job's* own failure, and nothing was ever queued
    /// to report it — so the gesture has to, rather than queueing a run that would answer nothing.
    @Test("a manifest that is not one is reported without queueing anything")
    func unreadableRemoteManifestIsReported() async throws {
        let root = VFSPath(backend: Handoff.remoteID, path: "/srv")
        let manifestRow = Handoff.remote("/srv/files.md5")
        let copy = try Handoff.temporaryFile(named: "files.md5")
        try Data("this is prose, not a checksum line\n".utf8).write(to: copy)

        let hosted = windowedPane(showing: [manifestRow], at: root)
        hosted.host.materializeReport = Handoff.report(landing: [(manifestRow, copy)])

        hosted.pane.verifyChecksums(nil)
        try await settleUntil { hosted.window.attachedSheet != nil }

        #expect(hosted.host.enqueued.isEmpty)
        #expect(
            sheetText(in: hosted.window)
                .contains(LocalizedCatalog.sentence(for: ChecksumError.manifestUnreadable))
        )
    }
}

/// Wait for something a `Task` will make true, generously — a satisfied predicate returns on the
/// next poll, so the budget only sets how much scheduling delay is absorbed before blaming the code
/// (docs/NOTES.md ▸ Testing). Never a run-loop spin: that drives layout but never lands the result
/// of a detached read, which is the exact shape being waited on here.
@MainActor
func settleUntil(within: Duration = .seconds(10), _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + within
    while ContinuousClock.now < deadline {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the gesture to settle")
}
