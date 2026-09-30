import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌥F5 over rows that are not on this disk, and into a folder that is not either (PLAN.md §M24
/// Slice 6).
///
/// Nothing here packs anything: `PackRunner` and `ArchivePacking` are tested in the core against
/// real bytes and a real writer. What an app test can see is the half the core cannot — which
/// gesture is refused, which sheet goes up, and what the pane hands the writer once the bytes have
/// landed.
@MainActor
@Suite("Pack over rows that are not local", .serialized)
struct PackMaterializeTests {
    /// A pane with a counterpart to pack into, both retained by the returned host.
    private func panes(
        showing entries: [FileEntry],
        at directory: VFSPath = .local("/tmp"),
        destination: VFSPath = .local("/tmp/dest"),
        backend: Handoff.StubBackend = Handoff.StubBackend()
    ) -> (WindowedPane, PanelViewController) {
        let source = windowedPane(showing: entries, at: directory, backend: backend)
        let (other, _) = hostedPane(at: destination, backend: backend)
        source.host.counterpart = other
        return (source, other)
    }

    // MARK: - Which sources may be packed

    @Test("a folder on a server is staged rather than refused")
    func remoteFolderIsStaged() async throws {
        // **This test used to assert the opposite**, and the sentence it pinned was the hand-off's:
        // a folder that is not here stands for an unknown number of objects in an unknown number of
        // requests, so ⌥F5 refused it and told the user to copy it over with F5 and pack the copy.
        // That advice *is* the implementation — `MaterializeRunner` hands the folder to
        // `CopyEngine`, which has walked remote trees since M5 — so since 2026-08-30 the gesture
        // does it instead of recommending it (PLAN.md §4 ▸ *Smaller than a milestone*).
        //
        // What has **not** changed is what the user is told beforehand: a plan holding a folder is
        // not exact, so the confirmation says Dirnex cannot tell in advance how much this will
        // fetch. That is `MaterializationPlan.totalsAreExact`, and it was written for this case
        // before anything could stage one.
        let folder = Handoff.remote("/srv/photos", kind: .directory)
        let (source, _) = panes(
            showing: [folder],
            at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        source.pane.panel.moveCursor(to: 0)

        source.pane.beginArchivePacking()
        try await settleUntil { source.window.attachedSheet != nil }

        // The pack sheet, not a refusal: it offers Pack, Cancel and its accessory's popups, where a
        // refusal offers one OK. Counting rather than matching text, since the test target inherits
        // the developer's own `AppleLanguages` pin (docs/NOTES.md ▸ Testing).
        #expect(sheetButtonCount(in: source.window) > 1)
        // That the folder then really is *staged and packed* cannot be seen from here: everything
        // after the Pack button is behind a sheet nothing headless can answer, which is the same
        // wall M24 Slice 6 met. It is measured in `PackLiveIntegrationTests` against a real server
        // and a real `bsdtar` (docs/NOTES.md ▸ Live verification).
        #expect(source.host.enqueued.isEmpty)
    }

    @Test("a folder that is already on this Mac still packs, as it always has")
    func localFolderIsUntouched() async throws {
        // The narrowness control for the refusal above, and the one that matters most: the ordinary
        // ⌥F5 is a folder, and a rule written as "refuse a folder" would have taken the feature away.
        let folder = Handoff.local("/tmp/docs", kind: .directory)
        let (source, _) = panes(showing: [folder])
        source.pane.panel.moveCursor(to: 0)

        source.pane.beginArchivePacking()
        try await settleUntil { source.window.attachedSheet != nil }

        #expect(sheetButtonCount(in: source.window) > 1)
    }

    @Test("a file on a server reaches the pack sheet")
    func remoteFileIsPackable() async throws {
        let file = Handoff.remote("/srv/report.pdf")
        let (source, _) = panes(
            showing: [file],
            at: VFSPath(backend: Handoff.remoteID, path: "/srv")
        )
        source.pane.panel.moveCursor(to: 0)

        source.pane.beginArchivePacking()
        try await settleUntil { source.window.attachedSheet != nil }

        // The sheet, not the refusal: nothing about packing needs a row to be local, only to be a
        // file — which is the whole of M24 in one assertion.
        #expect(sheetButtonCount(in: source.window) > 1)
    }

    // MARK: - Where the archive may go

    @Test("a destination that cannot be written to is refused before the sheet")
    func readOnlyDestinationIsRefused() async throws {
        let destination = VFSPath(backend: Handoff.remoteID, path: "/bucket")
        var backend = Handoff.StubBackend()
        backend.readOnlyPaths = [destination]
        let (source, _) = panes(
            showing: [Handoff.local("/tmp/a.txt")],
            destination: destination,
            backend: backend
        )
        source.pane.panel.moveCursor(to: 0)

        source.pane.beginArchivePacking()
        try await settleUntil { source.window.attachedSheet != nil }

        #expect(sheetButtonCount(in: source.window) == 1)
        #expect(source.host.enqueued.isEmpty)
    }

    @Test("a writable folder on a server is a destination like any other")
    func writableRemoteDestinationIsAccepted() async throws {
        // `capabilities(for:)` asked of the destination *directory*, which is what makes this one
        // question rather than one per backend: a writable bucket says yes, a read-only one says no,
        // and a browsed archive says no because `ArchiveBackend` advertises `.read` alone.
        let (source, _) = panes(
            showing: [Handoff.local("/tmp/a.txt")],
            destination: VFSPath(backend: Handoff.remoteID, path: "/bucket")
        )
        source.pane.panel.moveCursor(to: 0)

        source.pane.beginArchivePacking()
        try await settleUntil { source.window.attachedSheet != nil }

        #expect(sheetButtonCount(in: source.window) > 1)
    }

    // MARK: - What the writer is handed

    @Test("each source names its own directory, so a tree's marks at two depths both land")
    func sourcesCarryTheirOwnDirectories() throws {
        // ⌥F5 in a tree has been wrong since trees shipped: the pack was handed `panel.path` plus
        // bare names, so a marked row inside an expanded folder named a file that is not in the
        // pane's own directory — `bsdtar` failed, and the encrypted walk skipped the missing name
        // and wrote a smaller archive without saying so.
        let (pane, host) = hostedPane(at: .local("/tmp/root"))
        _ = host
        let shallow = Handoff.local("/tmp/root/alpha.txt")
        let deep = Handoff.local("/tmp/root/docs/report.pdf")

        let urls = try [shallow, deep].map { try #require(pane.materializedURL(for: $0)) }
        let sources = PanelViewController.packSources(for: urls)

        #expect(sources.map(\.directory) == ["/tmp/root", "/tmp/root/docs"])
        #expect(sources.map(\.name) == ["alpha.txt", "report.pdf"])
        // And the argv the writer gets keeps them apart, which is the claim that would have failed
        // before: one `-C` per directory, in order.
        let argv = ArchivePacking.packingArguments(
            archiveOnDiskPath: "/tmp/out.zip",
            sources: sources,
            format: .zip,
            level: .normal
        )
        #expect(argv.count(where: { $0 == "-C" }) == 2)
    }

    @Test("a staged copy is named by the file that is there, not by the row")
    func stagedSourcesFollowTheCopy() {
        // Both halves come from the same URL rather than one from the URL and the name from the
        // row, so they cannot disagree about a file that is provably on disk — and the merged
        // iCloud listing is the one row in this codebase where a row's name is not a file name.
        let sources = PanelViewController.packSources(for: [
            URL(fileURLWithPath: "/tmp/DirnexRemote/aaa/report.pdf"),
            URL(fileURLWithPath: "/tmp/DirnexRemote/bbb/report.pdf")
        ])
        #expect(sources.map(\.name) == ["report.pdf", "report.pdf"])
        #expect(sources.map(\.directory) == ["/tmp/DirnexRemote/aaa", "/tmp/DirnexRemote/bbb"])
    }
}

/// ⏎ on an archive that lives on a server (PLAN.md §M24 Slice 6).
///
/// `ArchiveBackend.init(archiveOnDiskPath:)` needs a real path, so browsing one is
/// fetch-the-whole-file-then-mount — the mirror of packing *to* a server. What an app test can see
/// is the routing and what the mount then is; the extraction itself is `ArchiveMounter`'s and is
/// covered where the bytes are.
@MainActor
@Suite("Browsing an archive on a server", .serialized)
struct RemoteArchiveBrowseTests {
    @Test("a browsable archive on a server routes to the browse, not to the default app")
    func remoteArchiveRoutesToBrowse() {
        let (pane, host) = hostedPane(at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        _ = host
        #expect(pane.remoteArchiveToBrowse(for: Handoff.remote("/srv/backup.zip")) != nil)
        #expect(pane.remoteArchiveToBrowse(for: Handoff.remote("/srv/notes.tar.gz")) != nil)
    }

    @Test("everything else on the same server keeps the route it had")
    func onlyArchivesTakeTheBrowseRoute() {
        // The narrowness control, and it is the one that matters: this branch sits *in front of*
        // the plain remote open, so an answer that was too wide would send every file on a server
        // into an archive mount instead of to the application that owns its type.
        let (pane, host) = hostedPane(at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        _ = host
        #expect(pane.remoteArchiveToBrowse(for: Handoff.remote("/srv/report.pdf")) == nil)
        // A *directory* named like an archive is still a directory to walk into.
        #expect(
            pane.remoteArchiveToBrowse(for: Handoff.remote("/srv/x.zip", kind: .directory)) == nil
        )
        // And a local archive keeps its own route, which needs no download at all.
        #expect(pane.remoteArchiveToBrowse(for: Handoff.local("/tmp/backup.zip")) == nil)
    }

    @Test("⏎ on a remote archive actually takes that route, not the one below it")
    func enterRoutesThroughTheBrowse() async throws {
        // The predicate answering is not the same as the key calling it — a route decided in one
        // file and undone in the one it calls is the shape this app has been caught by four times
        // (PLAN.md §M22 Slice 5). What the browse costs is a `.materialize` job, which is the one
        // thing the stub host records, so it doubles as the assertion that the key reached it.
        let zip = Handoff.remote("/srv/backup.zip")
        let pane = windowedPane(showing: [zip], at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        pane.pane.panel.moveCursor(to: 0)

        pane.pane.openCurrentEntry()
        try await settleUntil { !pane.host.materializedEntries.isEmpty }
        #expect(pane.host.materializedEntries.map { $0.map(\.path) } == [[zip.path]])
    }

    @Test("⏎ on an ordinary remote file does not take it")
    func enterOnAPlainFileIsUnchanged() {
        // The narrowness control for the branch above, which sits *in front of* the plain remote
        // open: that path goes through `RemoteFileCache` rather than through a queued job, so an
        // empty record here is what says the two are still apart.
        //
        // Read with no wait at all, and that is what makes it a control rather than a hopeful
        // negative: the whole route — the plan, the policy, the hand-over to the host — runs in the
        // turn `openCurrentEntry` was called on, which the test above measures from the other side.
        // A negative wait sized by a constant is the shape that goes vacuous (docs/NOTES.md ▸
        // Testing); there is nothing here for one to be sized against.
        let pdf = Handoff.remote("/srv/report.pdf")
        let pane = windowedPane(showing: [pdf], at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        pane.pane.panel.moveCursor(to: 0)

        pane.pane.openCurrentEntry()
        #expect(pane.host.materializedEntries.isEmpty)
    }

    @Test("the mount is read-only and walks back out to the server, not to the extraction")
    func theMountKnowsWhereItCameFrom() {
        // Recorded in the registry nested archives already use, because it is the same shape: the
        // mount's bytes are a copy of something that lives elsewhere. Three things follow, and all
        // three are what is wanted.
        let (pane, host) = hostedPane(at: VFSPath(backend: Handoff.remoteID, path: "/srv"))
        let origin = VFSPath(backend: Handoff.remoteID, path: "/srv/backup.zip")
        let mount = "/tmp/DirnexRemote/aaa/backup.zip"
        host.nestedArchiveRegistry.record(mountOnDiskPath: mount, origin: origin)

        // Read-only: F8, F5-into and paste all draw `isNestedArchive`, and a write here would land
        // in a temp file rather than in the archive on the server.
        pane.panel = Panel(
            model: DirectoryModel(
                listing: DirectoryListing(
                    path: pane.stagedArchiveRoot(atOnDiskPath: mount),
                    entries: []
                )
            )
        )
        #expect(pane.isNestedArchive)
        #expect(!pane.isWritableArchive)
        // And the way up is the server's own directory, never `/tmp/DirnexRemote/aaa`.
        #expect(host.nestedArchiveRegistry.origin(ofMountAt: mount) == origin)
        #expect(host.nestedArchiveRegistry.ancestry(ofMountAt: mount) == [origin])
    }

    @Test("the breadcrumb names the server rather than the temp directory it was staged in")
    func crumbsAreRootedAtTheServer() throws {
        // A location-derived backend id rather than a hand-built one, because the root crumb's title
        // comes from parsing that id (`backendRootTitle`) and a string that merely *looks* like one
        // answers `nil` — which is how the first version of this test read "Macintosh HD" and could
        // not tell that from the bug it was written for.
        let server = SFTPLocation(host: "example.com", username: "oleg")
        let origin = VFSPath(backend: .sftp(server), path: "/srv/backup.zip")
        let mount = VFSPath(
            backend: .archive(forArchiveAt: "/tmp/DirnexRemote/aaa/backup.zip"),
            path: "/docs"
        )
        let titles = PathBarView.archiveCrumbs(for: mount, ancestry: [origin]).map(\.title)

        // `Macintosh HD › private › tmp › DirnexRemote › <uuid>` is a directory nobody asked to see,
        // and every crumb in it is one the user cannot usefully click back to.
        #expect(!titles.contains("DirnexRemote"))
        #expect(!titles.contains("tmp"))
        // Exactly four, in order: the server, the directory the archive sits in, the archive, and
        // the folder open inside it. The **count** is what catches the remote origin being walked as
        // though it were an enclosing archive, which draws its own components a second time
        // (`… › srv › backup.zip › srv › backup.zip › docs`) and reads as a plausible trail.
        #expect(titles == ["oleg@example.com", "srv", "backup.zip", "docs"])
    }

    @Test("a nested archive inside one on a server keeps both frames, once each")
    func crumbsSpanARemoteChain() throws {
        // The narrowness control for "the origin is a container, not a frame": everything *after*
        // the remote origin still is one, so an inner archive gets its own name crumb and its own
        // inner directories — the chain a local nested archive draws, rooted at a server.
        let server = SFTPLocation(host: "example.com", username: "oleg")
        let outer = VFSPath(backend: .sftp(server), path: "/srv/backup.zip")
        let inner = VFSPath(
            backend: .archive(forArchiveAt: "/tmp/DirnexRemote/aaa/backup.zip"),
            path: "/docs/inner.zip"
        )
        let mount = VFSPath(
            backend: .archive(forArchiveAt: "/tmp/extract/bbb/inner.zip"),
            path: "/notes"
        )
        let titles = PathBarView.archiveCrumbs(for: mount, ancestry: [outer, inner]).map(\.title)

        #expect(titles == ["oleg@example.com", "srv", "backup.zip", "docs", "inner.zip", "notes"])
    }
}
