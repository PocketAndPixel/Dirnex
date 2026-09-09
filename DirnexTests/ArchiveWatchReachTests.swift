import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Who *asks* whether a browsed archive's file has changed (PLAN.md ▸ Still open).
///
/// The answer was already built and tested: `CompositeBackend.mountedArchive` stamps every mount
/// with an ``ArchiveIdentity`` and re-reads the table of contents the moment that stops describing
/// the file on disk, which `ArchiveCacheFreshnessTests` pins against a real zip repacked under the
/// same name. What was missing was the question — `startWatching` returned early for any backend
/// but `.local`, so the only things that ever put it were a navigation, a tab switch, or a write
/// Dirnex made itself. A `.zip` repacked in another window therefore went on listing its old
/// members for the life of the pane.
///
/// So these are about the *arming*, which is the half no cache test can see: the freshness rule
/// answers correctly to whoever calls it, including nobody.
@MainActor
@Suite("An archive pane's watcher")
struct ArchiveWatchReachTests {
    private enum Remote {
        static let sftp = VFSBackendID.sftp(
            SFTPLocation(host: "example.com", port: 22, username: "oleg")
        )
    }

    /// A real zip on disk, packed by `bsdtar` from real files and repackable under the same name —
    /// which is the gesture under test (delete-and-repack is how anyone redoes an archive), so it
    /// is the gesture the fixture makes.
    ///
    /// The arming tests below would be satisfied by any file, since `startWatching` only parses the
    /// backend id and hands a path to FSEvents. The end-to-end test is what needs it to be an
    /// archive a pane can actually list.
    private final class ArchiveFile {
        let directory: URL
        let path: String

        init(entries: [String: String] = ["one.txt": "first"]) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ArchiveWatchReachTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("pkg.zip").path
            try repack(entries: entries)
        }

        /// The pane's path when it is browsing this archive's root.
        var root: VFSPath { VFSPath(backend: .archive(forArchiveAt: path), path: "/") }

        func repack(entries: [String: String]) throws {
            let staging = directory.appendingPathComponent("staging-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (name, contents) in entries {
                try Data(contents.utf8).write(to: staging.appendingPathComponent(name))
            }
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
            process.arguments = ["-c", "--format", "zip", "-f", path, "-C", staging.path]
                + entries.keys.sorted()
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: staging)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// Poll until `condition` holds, or give up. Generous on purpose: a satisfied predicate returns
    /// on the next poll, so the budget only sets how much scheduling delay is absorbed before the
    /// pane is blamed (docs/NOTES.md ▸ Testing).
    private static func settle(
        within budget: Duration = .seconds(30),
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

    private static func treePane(at path: VFSPath) -> PanelViewController {
        let pane = pane(at: path)
        pane.viewMode = .tree
        pane.applyViewMode()
        return pane
    }

    // MARK: - The arming

    @Test("a pane browsing an archive watches the archive's own file")
    func listPaneWatchesTheArchiveFile() throws {
        let archive = try ArchiveFile()
        let pane = Self.pane(at: archive.root)

        pane.startWatching(archive.root)

        #expect(pane.watchedSources == [.local(archive.path)])
        #expect(pane.watcher != nil, "an archive pane is watching something")
    }

    /// The inner path is what a pane is usually standing on, and it names the same container.
    @Test("a pane inside a folder within the archive watches the same file")
    func innerPaneWatchesTheSameFile() throws {
        let archive = try ArchiveFile()
        let inner = VFSPath(backend: .archive(forArchiveAt: archive.path), path: "/docs/api")
        let pane = Self.pane(at: inner)

        pane.startWatching(inner)

        #expect(pane.watchedSources == [.local(archive.path)])
    }

    /// Tree mode had the same hole and its own reason for it: `treeWatchSources` drops every path
    /// FSEvents cannot watch, and every directory a tree rooted in an archive lists is an
    /// `archive:` path — so the set came out empty and the stream was torn down. Switching to tree
    /// mode inside an archive must not cost the pane its watcher.
    @Test("a tree rooted in an archive watches the archive file too")
    func treePaneWatchesTheArchiveFile() throws {
        let archive = try ArchiveFile()
        let pane = Self.treePane(at: archive.root)

        pane.startWatchingTree(force: true)

        #expect(pane.watchedSources == [.local(archive.path)])
        #expect(pane.watcher != nil, "an archive tree is watching something")
    }

    /// The archive file is watched *beside* that list, never inside it: handed to the multi-path
    /// directory stream it would arrive without `kFSEventStreamCreateFlagFileEvents`, which reports
    /// a file appearing and disappearing and not a rewrite in place — the quiet direction, and the
    /// exact case the identity check exists for.
    @Test("the archive path never enters the directory stream's source list")
    func archivePathsStayOutOfTheDirectoryStream() throws {
        let archive = try ArchiveFile()
        let pane = Self.treePane(at: archive.root)

        #expect(pane.treeWatchSources.isEmpty)
        #expect(!pane.treeWatchSources.contains(where: { $0.backend.isArchive }))
    }

    /// The rebuild guard. `startWatchingTree` runs on every tree refresh, and a stream torn down
    /// and rebuilt each time is the bug the merged-listing watcher already documents — so the
    /// archive file has to be what `watchedSources` records, or the set comparison never matches.
    @Test("re-arming an unchanged archive tree keeps the same stream")
    func reArmingDoesNotRebuildTheStream() throws {
        let archive = try ArchiveFile()
        let pane = Self.treePane(at: archive.root)
        pane.startWatchingTree(force: true)
        let armed = pane.watcher

        pane.startWatchingTree()

        #expect(pane.watcher === armed, "the same stream, not a fresh one per refresh")
        #expect(pane.watchedSources == [.local(archive.path)])
    }

    // MARK: - The whole chain

    /// The claim the slice is really making, driven end to end with **no gesture at all**: a real
    /// pane listing a real zip, the zip repacked on disk by another process, and the pane's rows
    /// following. Everything in between is the shipped path — the FSEvents stream, the hop to the
    /// main actor, `directoryDidChange`, `performListRefresh`, `DirectoryLoader`,
    /// `CompositeBackend.mountedArchive`, the ``ArchiveIdentity`` comparison, the `bsdtar` re-read
    /// and `installSortedModel`.
    ///
    /// Nothing else can make this claim. The cache tests call `listDirectory` themselves, which is
    /// the question rather than the asking; the arming tests read `watchedSources`, which says a
    /// stream exists and not that anything acts on it. And it cannot be driven from outside the
    /// app: session restore is `.local`-only, so a tab cannot come back inside an archive, and
    /// nothing in the `.sdef` or `CommandBinding` enters one.
    @Test("a repacked archive reaches the pane with nobody asking")
    func repackedArchiveRefreshesThePane() async throws {
        let archive = try ArchiveFile(entries: ["one.txt": "first", "two.txt": "second"])
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: archive.root,
            restorationKey: nil
        )
        // The pane's table has no columns and no rows until the view loads, so an unloaded pane
        // would read the same whatever the code did (the `RenameReachTests` lesson). Deafened right
        // after, so another suite writing a preference cannot repaint this one — every observer is
        // selector-based and installed once, and the FSEvents watcher is a stream callback rather
        // than a notification, so it is untouched.
        pane.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(pane)

        let listed = await Self.settle {
            pane.panel.displayedEntries.map(\.name).sorted() == ["one.txt", "two.txt"]
        }
        #expect(listed, "the pane never listed the archive it was pointed at")
        #expect(pane.watchedSources == [.local(archive.path)], "and it armed on the file")

        try archive.repack(entries: ["one.txt": "first"])

        let followed = await Self.settle {
            pane.panel.displayedEntries.map(\.name) == ["one.txt"]
        }
        #expect(followed, "the pane went on listing the archive that is no longer there")
    }

    // MARK: - Narrowness

    /// The control that stops "watch the archive file, whatever the pane is showing" from passing
    /// the tests above: an ordinary local pane still watches its own directory, by path.
    @Test("an ordinary local pane still watches its own directory")
    func localPaneIsUnchanged() {
        let home = VFSPath.local(NSHomeDirectory())
        let pane = Self.pane(at: home)

        pane.startWatching(home)

        #expect(pane.watchedSources == [home])
    }

    /// And the other half: a backend with no file behind it is still watching nothing. A server's
    /// listing is re-read on a timer instead (`PanelViewController+RemoteRefresh`), and a `.search`
    /// path is a snapshot of a question rather than a place.
    @Test("a pane on a server still watches nothing")
    func remotePaneIsUnchanged() {
        let remote = VFSPath(backend: Remote.sftp, path: "/home/oleg")
        let pane = Self.pane(at: remote)

        pane.startWatching(remote)

        #expect(pane.watchedSources.isEmpty)
        #expect(pane.watcher == nil)
    }
}
