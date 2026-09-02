import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where size-visualization mode is allowed to apply (PLAN.md ▸ Still open, "Size bars are
/// local-only for a cost reason that covers only half of what it gates").
///
/// The gate was `panel.path.backend == .local`, written twice by hand — once in
/// `areSizeBarsVisible` and once in the menu validator — and the cost argument behind it was wrong
/// about an archive and out of date about a server:
///
/// - An **archive** never cost anything. `DirectorySizeBudget.forBackend` has called it unbounded
///   since M21, which is why Space on a folder inside a zip has always sized it. Only the bars
///   refused.
/// - A **server** is bounded twice over now: ``DirectorySizer`` asks for the whole subtree before
///   walking it, and what cannot be answered that way runs under one allowance shared by the whole
///   set.
///
/// So these are about the gate, not about the bytes. What the bytes mean is `SizeVisualization`'s
/// and is tested in the core; that the shortcut and the walk agree is `DirectorySizer`'s. What
/// nothing else could see is that no one was asking.
@MainActor
@Suite("Where size bars apply", .serialized)
struct SizeBarReachTests {
    private enum Remote {
        static let sftp = VFSBackendID.sftp(
            SFTPLocation(host: "example.com", port: 22, username: "oleg")
        )
        static let s3 = VFSBackendID.s3(
            S3Location(host: "s3.example.com", bucket: "b", region: "eu-north-1", accessKeyID: "k")
        )
    }

    /// A real zip packed by `bsdtar` from real files, with two folders of deliberately different
    /// weights — the bar column's whole subject is the comparison between them.
    private final class ArchiveFile {
        let directory: URL
        let path: String

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("SizeBarReachTests-\(UUID().uuidString)")
            let staging = directory.appendingPathComponent("staging")
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent("big/nested"), withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: staging.appendingPathComponent("small"), withIntermediateDirectories: true
            )
            try Data(repeating: 0x61, count: 4000)
                .write(to: staging.appendingPathComponent("big/nested/payload.bin"))
            try Data(repeating: 0x62, count: 100)
                .write(to: staging.appendingPathComponent("small/leaf.bin"))
            path = directory.appendingPathComponent("pkg.zip").path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = [
                "-c", "--format", "zip", "-f", path, "-C", staging.path, "big", "small"
            ]
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: staging)
        }

        var root: VFSPath { VFSPath(backend: .archive(forArchiveAt: path), path: "/") }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Poll until `condition` holds. Generous on purpose: a satisfied predicate returns on the next
    /// poll, so the budget only sets how much scheduling delay is absorbed before the pane is
    /// blamed (docs/NOTES.md ▸ Testing).
    private static func settle(
        within budget: Duration = .seconds(10),
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    // MARK: - The gate

    @Test("an archive listing can carry bars")
    func archiveCanShowBars() throws {
        let archive = try ArchiveFile()

        #expect(Self.pane(at: archive.root).canShowSizeBars)
        #expect(
            Self.pane(at: VFSPath(backend: .archive(forArchiveAt: archive.path), path: "/big"))
                .canShowSizeBars,
            "a folder inside the archive, not only its root"
        )
    }

    /// The case the gate was written for, which the set allowance is what made affordable. The
    /// bound itself is the core's and is tested there; what is asserted here is that the pane stops
    /// refusing, for every connected backend rather than a list of cases.
    @Test("a connected server can carry them now")
    func remoteCanShowBars() {
        #expect(Self.pane(at: VFSPath(backend: Remote.sftp, path: "/home/oleg")).canShowSizeBars)
        #expect(Self.pane(at: VFSPath(backend: Remote.s3, path: "/data")).canShowSizeBars)
        // And what makes that affordable rather than merely allowed: one keystroke's whole spend is
        // bounded, where before this slice each of N rows was entitled to the full budget.
        #expect(
            DirectorySizeBudget.forSet(ofBackend: Remote.s3).directoryLimit
                == DirectorySizeBudget.remote.directoryLimit
        )
    }

    /// The one exclusion left, and it is not about cost: a synthetic listing's rows live in a dozen
    /// different folders, so "share of this directory" has no referent however cheap the walk would
    /// be. This is the narrowness control on lifting the gate — three backends that a
    /// cost-shaped rule would now wave through.
    @Test("a virtual listing refuses them for its own reason")
    func virtualListingsRefuse() {
        for backend in [VFSBackendID.search, .trash, .icloud] {
            #expect(
                !Self.pane(at: VFSPath(backend: backend, path: "/")).canShowSizeBars,
                "\(backend) has no directory to be a share of"
            )
        }
    }

    @Test("an ordinary local directory is unchanged")
    func localIsUnchanged() {
        #expect(Self.pane(at: .local(NSHomeDirectory())).canShowSizeBars)
    }

    /// The menu item and the pane read **one** property. They were two hand-copies of
    /// `backend == .local`, and the archive defect was in both — so the assertion is agreement over
    /// every shape, not the value of either alone.
    @Test("the View menu item is enabled exactly where the bars can apply")
    func menuValidationMatchesTheGate() throws {
        let archive = try ArchiveFile()
        let paths: [VFSPath] = [
            .local(NSHomeDirectory()),
            archive.root,
            VFSPath(backend: Remote.sftp, path: "/home/oleg"),
            VFSPath(backend: Remote.s3, path: "/data"),
            VFSPath(backend: .trash, path: "/"),
            VFSPath(backend: .search, path: "/")
        ]
        let item = NSMenuItem(
            title: "Size Visualization",
            action: #selector(PanelViewController.toggleSizeVisualization(_:)),
            keyEquivalent: ""
        )
        for path in paths {
            let pane = Self.pane(at: path)
            #expect(
                pane.validateMenuItem(item) == pane.canShowSizeBars,
                "the menu and the pane disagree about \(path.backend)"
            )
        }
    }

    // MARK: - The whole chain

    /// The claim the slice makes, driven end to end: a real pane listing a real zip, the mode
    /// switched on with the shipped command, and a bar arriving on a folder inside the archive with
    /// the archive's own bytes in it. Everything between is the shipped path — `updateSizeVisualization`,
    /// the column install, `SizeVisualization.pendingDirectories`, `DirectorySizeProvider`'s queue,
    /// `DirectoryLoader.cancellableSize`, `DirectorySizer` walking the `ArchiveBackend` through the
    /// composite, the publish, and the re-seed.
    ///
    /// Nothing else can make it. The gate tests read a property; the core's tests walk a backend
    /// nobody asked. And it cannot be driven from outside the app — session restore is `.local`-only,
    /// so a tab cannot come back inside an archive, and nothing in the `.sdef` enters one.
    @Test("switching the mode on inside a zip draws real bars")
    func barsAppearInsideAnArchive() async throws {
        let archive = try ArchiveFile()
        let pane = Self.pane(at: archive.root)
        // The table has no columns until the view loads, so the column assertion below would read
        // the same whatever the code did (the `RenameReachTests` lesson). Deliberately *not*
        // deafened afterwards: this pane's own size-provider observer is a notification, so
        // `removeObserver` would cut the wire under test.
        pane.loadViewIfNeeded()

        let listed = await Self.settle {
            pane.panel.displayedEntries.map(\.name).sorted() == ["big", "small"]
        }
        #expect(listed, "the pane never listed the archive it was pointed at")
        #expect(
            pane.sizeBar(for: try #require(pane.panel.displayedEntries.first)) == nil,
            "no bars before the mode is on"
        )

        pane.toggleSizeVisualization(nil)
        #expect(pane.areSizeBarsVisible)
        #expect(pane.isSizeBarColumnInstalled, "the bar column belongs on an archive listing")

        func bar(_ name: String) -> SizeBar? {
            pane.panel.displayedEntries.first { $0.name == name }.flatMap { pane.sizeBar(for: $0) }
        }
        let walked = await Self.settle { bar("big") != nil && bar("small") != nil }
        #expect(walked, "the auto-scan never sized the archive's folders")

        // The archive's own bytes, not the zip file's: 4000 and 100, walked through a table of
        // contents rather than off this disk.
        #expect(bar("big")?.bytes == 4000)
        #expect(bar("small")?.bytes == 100)
        // And the comparison the column exists for — the heavier folder fills the bar.
        #expect(bar("big")?.fraction == 1.0)
        #expect((bar("small")?.fraction ?? 0) < 0.05)
    }

    // MARK: - A row the set's allowance never reached

    /// The wire between the queue giving up on a row and the row saying so.
    ///
    /// `DirectorySizeProvider` bounds a whole bar column with one allowance, so on a server some
    /// rows can be refused rather than merely unwalked — and those are opposite facts that look
    /// identical, because both leave the size column at a dash. The publish carries them
    /// (`gaveUpKey`) and the pane routes them into the give-up marker Space-on-dir already draws,
    /// with the tooltip that already explains it in fourteen languages.
    @Test("a published give-up marks the row it names")
    func publishedGiveUpsMarkTheirRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SizeBarReachTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("child"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = VFSPath.local(directory.path)
        let pane = Self.pane(at: root)
        pane.loadViewIfNeeded()
        let listed = await Self.settle { pane.panel.displayedEntries.map(\.name) == ["child"] }
        #expect(listed)
        pane.toggleSizeVisualization(nil)

        let child = try #require(pane.panel.displayedEntries.first)
        #expect(pane.directorySizeState(for: child) == .idle, "nothing refused yet")

        NotificationCenter.default.post(
            name: DirectorySizeProvider.didChangeNotification,
            object: nil,
            userInfo: [
                DirectorySizeProvider.directoryKey: root,
                DirectorySizeProvider.scopeKey: DirectorySizeScope.all,
                DirectorySizeProvider.totalsKey: [VFSPath: Int64](),
                DirectorySizeProvider.gaveUpKey: Set([child.path])
            ]
        )

        #expect(pane.directorySizeState(for: child) == .gaveUp)
        // And it is a *refusal*, not a total: the row must still carry no bar, or the give-up would
        // be drawn as a measured zero — the "Zero KB · 0.0 %" lie `SizeVisualization` exists to
        // avoid, arriving from the other direction.
        #expect(pane.sizeBar(for: child) == nil)
    }

    /// The narrowness half: an ordinary publish carrying only totals marks nothing. Without it,
    /// "mark whatever the notification names" would pass the test above by marking every row.
    @Test("a publish with no give-ups marks nothing")
    func ordinaryPublishMarksNothing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SizeBarReachTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("child"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = VFSPath.local(directory.path)
        let pane = Self.pane(at: root)
        pane.loadViewIfNeeded()
        let listed = await Self.settle { pane.panel.displayedEntries.map(\.name) == ["child"] }
        #expect(listed)
        pane.toggleSizeVisualization(nil)
        let child = try #require(pane.panel.displayedEntries.first)

        NotificationCenter.default.post(
            name: DirectorySizeProvider.didChangeNotification,
            object: nil,
            userInfo: [
                DirectorySizeProvider.directoryKey: root,
                DirectorySizeProvider.scopeKey: DirectorySizeScope.all,
                DirectorySizeProvider.totalsKey: [child.path: Int64(4096)]
            ]
        )

        #expect(pane.directorySizeState(for: child) == .idle)
        #expect(pane.sizeBar(for: child)?.bytes == 4096, "the total still lands")
    }

    // MARK: - Staleness

    /// A pane inside a zip watches the **container file**, so its wake says the whole archive was
    /// rewritten — a repack under the same name is how anyone redoes one, and every inner path
    /// keeps its `archive:<on-disk path>` identity across it. Invalidating only the pane's own
    /// root-to-leaf line would leave a sibling folder's total banked against an archive that no
    /// longer exists.
    @Test("an archive's wake invalidates the whole container, not one line of it")
    func archiveInvalidationCoversTheWholeArchive() {
        let backend = VFSBackendID.archive(forArchiveAt: "/tmp/pkg.zip")
        let inner = VFSPath(backend: backend, path: "/docs/api")

        let root = PanelViewController.sizeInvalidationRoot(for: inner)

        #expect(root == VFSPath(backend: backend, path: "/"))
        // A sibling the pane was not standing in is on the invalidated line only because of the
        // widening — this is the assertion that fails if it is removed.
        #expect(VFSPath(backend: backend, path: "/images").isSelfOrDescendant(of: root))
    }

    /// The narrowness half: a local pane's stream really is rooted at the directory on screen, so
    /// its own line is exactly what the ping proves and a sibling's total must survive.
    @Test("a local wake still invalidates only its own line")
    func localInvalidationIsUnchanged() {
        let watched = VFSPath.local("/Users/oleg/Dev")

        let root = PanelViewController.sizeInvalidationRoot(for: watched)

        #expect(root == watched)
        #expect(!VFSPath.local("/Users/oleg/Movies").isSelfOrDescendant(of: root))
    }
}
