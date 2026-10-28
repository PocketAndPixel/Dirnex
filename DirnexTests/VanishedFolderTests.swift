import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A pane whose folder is deleted under it moves up to the nearest folder that still exists, on
/// every refresh path that can find it gone (`PanelViewController+VanishedFolder`).
///
/// Seen live 2026-10-24: Put Back pruned the NAS bin folder a pane was showing, and the pane kept
/// listing the file that had just left it. Every refresh read a failed listing as "keep the rows".
/// These run on this disk, where the same paths fail the same way and need no server: the walk is
/// the core's (`FolderRefugeTests`), and what is pinned here is that each refresh reaches it.
///
/// **Each pane is hosted in a window that is never shown**, because only a pane in a window moves.
/// A pane in no window is what every other app test builds, and those outlive their tests: without
/// that rule, deleting their fixtures walked them into the temp folder and stalled the suite. So
/// the window is taken away before the fixture is deleted, and the no-window case is its own test.
@MainActor
@Suite("A pane whose folder vanished", .serialized)
struct VanishedFolderTests {
    /// `<root>/kept/gone/file.txt`, the pane's folder being `gone`.
    private static func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-vanished-\(UUID().uuidString)")
        let gone = root.appendingPathComponent("kept/gone")
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: gone.appendingPathComponent("file.txt"))
        return root
    }

    /// A pane and the window it may sit in. `close()` runs before the fixture is deleted, so the
    /// cleanup cannot walk the pane anywhere.
    @MainActor
    private final class Hosted {
        let pane: PanelViewController
        private var window: NSWindow?

        init(_ pane: PanelViewController, windowed: Bool) {
            self.pane = pane
            guard windowed else {
                pane.loadViewIfNeeded()
                return
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: true
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = pane
            self.window = window
        }

        func close() {
            pane.watcher = nil
            window?.contentViewController = nil
            window?.close()
            window = nil
        }
    }

    /// A loaded pane that has listed `folder`. `watching: false` drops the FSEvents watcher, so a
    /// test of one refresh path is not passed by the watcher reaching the same code first.
    private static func pane(
        at folder: URL,
        tree: Bool = false,
        watching: Bool = false,
        windowed: Bool = true
    ) async throws -> Hosted {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(folder.path),
            restorationKey: nil
        )
        let hosted = Hosted(pane, windowed: windowed)
        NotificationCenter.default.removeObserver(pane)
        if tree {
            pane.viewMode = .tree
            pane.applyViewMode()
        }
        try await settleUntil { pane.panel.displayedEntries.map(\.name) == ["file.txt"] }
        if !watching { pane.watcher = nil }
        return hosted
    }

    /// Hold long enough to show nothing moved. Fixed rather than scaled: its length is the claim.
    private static func hold() async {
        try? await Task.sleep(for: .seconds(1.5))
    }

    @Test("an operation's refresh that finds the folder gone moves the pane to its parent")
    func operationRefresh() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("kept/gone")
        let hosted = try await Self.pane(at: gone)
        defer { hosted.close() }

        try FileManager.default.removeItem(at: gone)
        hosted.pane.refreshCurrentDirectory()

        let kept = VFSPath.local(root.appendingPathComponent("kept").path)
        try await settleUntil { hosted.pane.panel.path == kept }
        #expect(hosted.pane.panel.path == kept)
    }

    @Test("the watcher's refresh walks past every folder deleted with it")
    func watcherRefresh() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = try await Self.pane(
            at: root.appendingPathComponent("kept/gone"),
            watching: true
        )
        defer { hosted.close() }

        // `kept` goes with it, so the nearest folder left is the fixture's root.
        try FileManager.default.removeItem(at: root.appendingPathComponent("kept"))

        try await settleUntil { hosted.pane.panel.path == .local(root.path) }
        #expect(hosted.pane.panel.path == .local(root.path))
    }

    @Test("a tree whose root is gone moves up too")
    func treeRefresh() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("kept/gone")
        let hosted = try await Self.pane(at: gone, tree: true)
        defer { hosted.close() }

        try FileManager.default.removeItem(at: gone)
        hosted.pane.refreshTree()

        let kept = VFSPath.local(root.appendingPathComponent("kept").path)
        try await settleUntil { hosted.pane.panel.path == kept }
        #expect(hosted.pane.panel.path == kept)
    }

    @Test("switching back to a tab whose folder went while it was hidden moves it up")
    func tabSwitch() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("kept/gone")
        let hosted = try await Self.pane(at: gone)
        defer { hosted.close() }
        let pane = hosted.pane
        pane.addTab()
        // Listed before it is left: a tab that never loaded is *navigated* when it comes back, which
        // is a load that reports its failure, not the refresh under test.
        try await settleUntil { pane.activeTabIndex == 1 && pane.tabs[1].hasLoaded }
        pane.selectTab(at: 0)
        pane.watcher = nil

        try FileManager.default.removeItem(at: gone)
        pane.selectTab(at: 1)
        pane.watcher = nil

        let kept = VFSPath.local(root.appendingPathComponent("kept").path)
        try await settleUntil { pane.panel.path == kept }
        #expect(pane.panel.path == kept)
    }

    @Test("a folder that is there but cannot be read keeps the pane where it is")
    func unreadableFolderStays() async throws {
        let root = try Self.fixture()
        let gone = root.appendingPathComponent("kept/gone")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: gone.path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let hosted = try await Self.pane(at: gone)
        defer { hosted.close() }

        // The listing fails as a refusal rather than "not found", and the folder still answers a
        // `stat`: nothing about it says the place is gone.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: gone.path)
        hosted.pane.refreshCurrentDirectory()
        await Self.hold()

        #expect(hosted.pane.panel.path == .local(gone.path))
    }

    @Test("a pane in no window stays where it was")
    func paneInNoWindowStays() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("kept/gone")
        let hosted = try await Self.pane(at: gone, windowed: false)
        defer { hosted.close() }

        try FileManager.default.removeItem(at: gone)
        hosted.pane.refreshCurrentDirectory()
        await Self.hold()

        #expect(hosted.pane.panel.path == .local(gone.path))
    }
}
