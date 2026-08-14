import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Space-on-dir over a backend whose listings are **billed round trips** (PLAN.md §M21 Slice 11).
///
/// Measured before any of this was written, against the live third-party S3 endpoint through the
/// real `S3Backend` and the app's own `S3CurlTransport`: one `ListObjectsV2` per directory, issued
/// serially, at 0.601–0.699 s each. A ten-directory prefix therefore cost 6.21 s and ten billed
/// requests, and it scaled linearly — a thousand-directory one is ten minutes and a thousand
/// requests. What shipped before this slice ran that walk with **no bound**, passing no
/// `isCancelled` at all and inside a `Task.detached` whose own doc comment says it deliberately
/// outlives its caller's cancellation, so navigating away discarded the *result* while the requests
/// kept going.
///
/// Three claims are pinned here and each fails differently: the walk **stops** at the budget, it is
/// **abandoned** when the pane stops looking, and a local walk is **untouched** by any of it. The
/// last is not padding — the easy wrong fix is to bound and cancel every walk, which would throw
/// away a local total that costs nothing to finish and is worth banking.
///
/// The fake backend is what makes the first claim assertable at all: a real fixture with 1001
/// directories in it is a fixture nobody would keep, and the count of listings *made* is the only
/// assertion that can see the difference between a request refused and a request made and then
/// discarded — on a billed backend those are different numbers.

/// A backend of infinite depth: every directory holds exactly one subdirectory and one 1-byte file.
///
/// Unbounded by construction, which is the point — under the old code this walk never terminates,
/// and under the new one it stops at exactly `directoryLimit`. It touches no disk and no network,
/// so the whole suite runs in milliseconds.
private final class BottomlessBackend: VFSBackend, @unchecked Sendable {
    let backendID: VFSBackendID
    private let lock = NSLock()
    private var count = 0
    /// Held so a test can watch the walk actually progress before cancelling it.
    var listingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    init(id: VFSBackendID) { backendID = id }

    var id: VFSBackendID { backendID }
    var capabilities: VFSCapabilities { [.read] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        count += 1
        lock.unlock()
        return [
            Self.entry(at: path.appending("sub"), kind: .directory),
            Self.entry(at: path.appending("leaf.bin"), kind: .file)
        ]
    }

    func stat(at path: VFSPath) throws -> FileEntry { Self.entry(at: path, kind: .directory) }

    static func entry(at path: VFSPath, kind: FileEntry.Kind) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: kind == .file ? 1 : 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o755,
            inode: 0
        )
    }
}

@MainActor
@Suite("Remote directory sizing")
struct RemoteDirectorySizeTests {
    private static let bucket = S3Location(
        host: "s3.eu-central-1.amazonaws.com",
        bucket: "photos",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private static var remoteBackendID: VFSBackendID { .s3(bucket) }

    /// A pane standing in `directory`, and the folder row named `folder` from its **own** listing.
    ///
    /// `loadViewIfNeeded()` for the reason `RenameReachTests` records: several of the flows under
    /// test touch the table, and an unloaded pane's table has no columns, so a broken version would
    /// return one guard earlier and the suite would pass against it. Safe headlessly now that a
    /// failed listing no longer raises an alert on a window-less pane (PLAN.md §M21).
    ///
    /// **The row comes from the pane's real navigation rather than from a model installed on top of
    /// it, and that is not tidiness.** Loading the view runs `viewDidLoad` → `activateTab` →
    /// `navigate`, which lists asynchronously; a fixture model assigned straight afterwards is
    /// replaced when that listing lands. Measured: a walk that finished in ~1 ms had its total
    /// wiped by the arriving listing and read as "the size never landed", while the same test over
    /// a backend slow enough to lose the race the other way passed. Awaiting the pane's own listing
    /// removes the race instead of widening a timeout around it.
    private static func pane(
        at directory: VFSPath,
        backend: any VFSBackend,
        folder: String
    ) async throws -> (PanelViewController, FileEntry) {
        let pane = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
        pane.loadViewIfNeeded()
        let arrived = await wait { rows(of: pane).contains { $0.name == folder } }
        #expect(arrived, "the pane never listed its own directory")
        let entry = try #require(rows(of: pane).first { $0.name == folder })
        return (pane, entry)
    }

    /// The pane's visible rows. `DirectoryModel` exposes a count and a subscript rather than an
    /// array, which is the shape the table asks it for.
    private static func rows(of pane: PanelViewController) -> [FileEntry] {
        (0..<pane.panel.model.count).map { pane.panel.model[$0] }
    }

    /// Polls rather than spinning the run loop: the walk lands through a detached task, and a
    /// run-loop spin drives layout without ever letting the main actor suspend, so the result
    /// simply never arrives (docs/NOTES.md ▸ Testing).
    private static func wait(
        upTo seconds: Double = 5,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    // MARK: - The budget stops the walk

    @Test("a bottomless remote folder stops at the budget instead of walking forever")
    func remoteWalkStopsAtBudget() async throws {
        let directory = VFSPath(backend: Self.remoteBackendID, path: "/dir")
        let backend = BottomlessBackend(id: Self.remoteBackendID)
        let (pane, folder) = try await Self.pane(at: directory, backend: backend, folder: "sub")

        // The pane lists its own directory when the view loads, so what the walk spent is a
        // *delta*. Measured the hard way: asserting the raw count read 1001 against a budget of
        // 1000 and looked like an off-by-one in the sizer, which it was not.
        let baseline = backend.listingCount
        pane.computeDirectorySize(for: folder)
        let finished = await Self.wait(upTo: 20) { pane.directorySizeWalks[folder.path] == nil }

        #expect(finished, "the walk must terminate rather than run forever")
        // Exactly the budget, not one more: the limit refuses the request rather than making it and
        // throwing the answer away, and on a billed backend that is the number that was spent.
        let limit = try #require(DirectorySizeBudget.remote.directoryLimit)
        #expect(backend.listingCount - baseline == limit)
        // And no number was invented from the part that was walked.
        #expect(pane.panel.computedSize(of: folder) == nil)
        #expect(pane.directorySizeState(for: folder) == .gaveUp)
    }

    @Test("a folder inside the budget still gets its real total")
    func withinBudgetStillTotals() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        try tree.makeDirectory("small")
        try tree.writeFile("small/a.bin", bytes: 40)
        try tree.writeFile("small/b.bin", bytes: 60)

        // A *remote* path over a real local walk: the budget is decided by the path's backend and
        // the bytes by the backend the pane holds, so this exercises the budgeted branch on a tree
        // that fits inside it — the case that must not be refused.
        let directory = VFSPath(backend: Self.remoteBackendID, path: tree.root.path)
        let (pane, folder) = try await Self.pane(
            at: directory,
            backend: RelabelledLocalBackend(id: Self.remoteBackendID),
            folder: "small"
        )

        pane.computeDirectorySize(for: folder)
        let landed = await Self.wait { pane.panel.computedSize(of: folder) != nil }

        #expect(landed)
        #expect(pane.panel.computedSize(of: folder) == 100)
        #expect(pane.directorySizeState(for: folder) == .idle)
    }

    // MARK: - Abandoning it

    @Test("navigating away cancels the walk this pane was paying for")
    func navigatingAwayCancels() async throws {
        let directory = VFSPath(backend: Self.remoteBackendID, path: "/dir")
        let backend = BottomlessBackend(id: Self.remoteBackendID)
        let (pane, folder) = try await Self.pane(at: directory, backend: backend, folder: "sub")

        pane.computeDirectorySize(for: folder)
        #expect(pane.directorySizeWalks[folder.path] != nil, "the walk is tracked while in flight")
        // Let it get going, so what is measured is a walk stopped mid-flight rather than one that
        // had not started.
        _ = await Self.wait(upTo: 2) { backend.listingCount > 5 }

        pane.cancelUnwatchedDirectorySizeWalks()
        let listedAtCancel = backend.listingCount

        #expect(pane.directorySizeWalks.isEmpty)
        // The claim is that the requests *stopped*, not merely that the answer was discarded — the
        // shipped bug was exactly the second thing wearing the first's clothes. A short grace
        // window covers the listing already in flight when cancel landed.
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            backend.listingCount <= listedAtCancel + 1,
            "listings continued after cancel: \(listedAtCancel) → \(backend.listingCount)"
        )
    }

    @Test("re-pressing Space on a folder already being measured does not start a second walk")
    func rePressDoesNotDuplicate() async throws {
        let directory = VFSPath(backend: Self.remoteBackendID, path: "/dir")
        let backend = BottomlessBackend(id: Self.remoteBackendID)
        let (pane, folder) = try await Self.pane(at: directory, backend: backend, folder: "sub")

        pane.computeDirectorySize(for: folder)
        _ = await Self.wait(upTo: 2) { backend.listingCount > 3 }
        pane.computeDirectorySize(for: folder)

        // One tracked walk, not two. `Task` is a value type so identity cannot be compared; what
        // says a second walk was not started is that a second one would be listing in parallel and
        // the dictionary would hold it.
        #expect(pane.directorySizeWalks.count == 1)
        #expect(pane.directorySizeWalks[folder.path] != nil)
        pane.cancelUnwatchedDirectorySizeWalks()
    }

    // MARK: - The local walk is untouched

    /// The easy wrong fix is to bound and cancel *every* walk. Locally nothing is spent finishing
    /// one and the total is worth banking, which is `DirectoryLoader.size`'s own argument — so a
    /// local walk stays untracked, and this is what says so.
    @Test("a local folder is not tracked, bounded or cancellable")
    func localWalkIsUntracked() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        try tree.makeDirectory("stuff")
        try tree.writeFile("stuff/a.bin", bytes: 7)

        let directory = VFSPath.local(tree.root.path)
        let (pane, folder) = try await Self.pane(
            at: directory, backend: LocalBackend(), folder: "stuff"
        )

        pane.computeDirectorySize(for: folder)
        #expect(pane.directorySizeWalks.isEmpty, "a local walk is fire-and-forget, not tracked")

        let landed = await Self.wait { pane.panel.computedSize(of: folder) != nil }
        #expect(landed)
        #expect(pane.panel.computedSize(of: folder) == 7)
    }
}

/// `LocalBackend`'s bytes under another backend's id, so a budgeted walk can be driven over a real
/// temp tree. Only the id is a fiction; every listing is the real thing.
private final class RelabelledLocalBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let backendID: VFSBackendID

    init(id: VFSBackendID) { backendID = id }

    var id: VFSBackendID { backendID }
    var capabilities: VFSCapabilities { [.read] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try inner.listDirectory(at: VFSPath.local(path.path)).map { entry in
            // `FileEntry.path` is a `let`, so the row is rebuilt rather than edited — only the
            // backend id changes, and every byte count is the real one.
            FileEntry(
                path: VFSPath(backend: backendID, path: entry.path.path),
                name: entry.name,
                kind: entry.kind,
                byteSize: entry.byteSize,
                modificationDate: entry.modificationDate,
                creationDate: entry.creationDate,
                isHidden: entry.isHidden,
                permissions: entry.permissions,
                inode: entry.inode
            )
        }
    }

    func stat(at path: VFSPath) throws -> FileEntry {
        try inner.stat(at: VFSPath.local(path.path))
    }
}

/// What the size column draws, which is the whole visible half of this slice. Pure, so it is pinned
/// directly rather than through a pane.
@MainActor
@Suite("Size column states")
struct DirectorySizeDisplayTests {
    private static func folder() -> FileEntry {
        BottomlessBackend.entry(at: .local("/tmp/dir"), kind: .directory)
    }

    @Test("an unmeasured folder still draws the dash it always did")
    func idleDrawsDash() {
        #expect(FileFormatting.sizeString(for: Self.folder()) == "—")
    }

    /// The state that did not exist before this slice: locally a walk is over before a frame is
    /// drawn, and over a network it is seconds per folder with nothing on screen to say so.
    @Test("a folder being measured is distinguishable from one that never was")
    func measuringIsDistinct() {
        let measuring = FileFormatting.sizeString(for: Self.folder(), state: .measuring)
        let idle = FileFormatting.sizeString(for: Self.folder(), state: .idle)
        #expect(measuring != idle)
        #expect(measuring == "…")
    }

    /// The one that matters most: a give-up drawing the same dash as "never measured" invites the
    /// user to press Space again and spend the whole budget a second time.
    @Test("a folder that gave up is distinguishable from both")
    func gaveUpIsDistinct() {
        let gaveUp = FileFormatting.sizeString(for: Self.folder(), state: .gaveUp)
        #expect(gaveUp != FileFormatting.sizeString(for: Self.folder(), state: .idle))
        #expect(gaveUp != FileFormatting.sizeString(for: Self.folder(), state: .measuring))
    }

    @Test("a real total outranks every state")
    func totalWins() {
        for state in [DirectorySizeDisplayState.idle, .measuring, .gaveUp] {
            let text = FileFormatting.sizeString(
                for: Self.folder(), computedSize: 2048, state: state
            )
            #expect(text.contains("2"), "a known total must be drawn whatever the state")
        }
    }

    @Test("a file's own size ignores the state entirely")
    func fileIgnoresState() {
        let file = BottomlessBackend.entry(at: .local("/tmp/f.bin"), kind: .file)
        #expect(
            FileFormatting.sizeString(for: file, state: .measuring)
                == FileFormatting.sizeString(for: file, state: .idle)
        )
    }
}

/// The two shapes this suite needs from the shared `TempDirectory`, which was written for files
/// with string contents. Kept here rather than widened onto the type, since nothing else asks a
/// scratch directory for a subfolder or for a file of a given byte count.
private extension TempDirectory {
    var path: String { root.path }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(relative), withIntermediateDirectories: true
        )
    }

    func writeFile(_ relative: String, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes)
            .write(to: root.appendingPathComponent(relative))
    }
}
