import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tab's back/forward trail across a relaunch, a ⌘[ that meets a folder deleted since, and a closed
/// tab handed to the window so ⇧⌘T can bring it back with its trail.
///
/// What the core decides — which entries are written, what a gone folder does to the trail — is
/// pinned in `NavigationHistoryStorageTests` and `NavigationHistoryWalkTests`. What is asserted here
/// is the wiring a headless test can reach: that a real pane writes its trail where restore reads it,
/// that a restored trail's server endpoints reach the reconnect decision, that a real listing of a
/// deleted folder is what skips it, and that a closed tab leaves the pane whole.
@MainActor
@Suite("Tab history")
struct TabHistoryTests {
    private static let sftpLocation = SFTPLocation(host: "example.com", username: "oleg")
    private static let sftpEndpoint = ServerEndpoint.sftp(
        location: sftpLocation,
        authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
    )

    /// Folders of its own, so nothing lists the home directory (docs/NOTES.md ▸ Testing).
    private static func scratch(_ names: [String]) throws -> (root: URL, paths: [VFSPath]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabHistoryTests-\(UUID().uuidString)")
        var paths: [VFSPath] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            paths.append(.local(url.path))
        }
        return (root, paths)
    }

    /// A pane, the host it reports to, and the key it saves its tabs under — named rather than a
    /// tuple, which SwiftLint caps at two members.
    private struct HostedPane {
        let pane: PanelViewController
        let host: StubPanelHost
        let key: String
    }

    /// A pane saving into the scratch domain under a key of its own, with a host to report to.
    private static func pane(at path: VFSPath) -> HostedPane {
        let key = "tab-history-\(UUID().uuidString)"
        let host = StubPanelHost()
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: path,
            restorationKey: key
        )
        pane.tabStateDefaults = TabStateScratch.defaults
        pane.host = host
        return HostedPane(pane: pane, host: host, key: key)
    }

    /// Walk `pane` through `paths` in order, each landing before the next.
    private static func visit(_ paths: [VFSPath], in pane: PanelViewController) async throws {
        for path in paths {
            pane.navigate(to: path)
            try await settleUntil { pane.panel.path == path && pane.tabs[pane.activeTabIndex].hasLoaded }
        }
    }

    // MARK: - Across a relaunch

    @Test("a pane writes each tab's trail and a relaunch brings it back, forward entries included")
    func trailSurvivesARelaunch() async throws {
        let (root, paths) = try Self.scratch(["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = Self.pane(at: paths[0])
        let (pane, key) = (hosted.pane, hosted.key)
        try await Self.visit(paths, in: pane)
        pane.goBack(nil)
        try await settleUntil { pane.panel.path == paths[1] && pane.tabs[0].history.walk == nil }
        pane.persistState()

        let saved = try #require(TabPersistence.load(paneKey: key, from: TabStateScratch.defaults))
        #expect(saved.tabs.first?.history?.entries == paths)
        #expect(saved.tabs.first?.history?.currentIndex == 1)

        let restored = try #require(PanelViewController.restoredTabs(from: saved).first)
        #expect(restored.history.entries == paths)
        #expect(restored.history.currentPath == paths[1])
        #expect(restored.history.canGoForward)
    }

    @Test("a restored trail's server endpoint is what ⌘[ reconnects with")
    func restoredTrailCarriesItsEndpoints() throws {
        let (root, paths) = try Self.scratch(["here"])
        defer { try? FileManager.default.removeItem(at: root) }
        let server = VFSPath(backend: .sftp(Self.sftpLocation), path: "/var/log")
        let history = StoredNavigationHistory(
            entries: [server, paths[0]],
            currentIndex: 1,
            endpoints: [Self.sftpEndpoint]
        )
        let tab = PersistedTab(path: paths[0], sort: .default, columns: nil, history: history)
        let restoration = PersistedPane(tabs: [tab], activeIndex: 0)

        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: restoration,
            defaultPath: paths[0],
            restorationKey: nil
        )
        #expect(pane.tabs[0].history.entries == [server, paths[0]])
        #expect(pane.tabs[0].endpoint(for: server.backend) == Self.sftpEndpoint)
        // Key-file SFTP needs no secret, so the decision is reached without the Keychain.
        let verdict = pane.reconnectVerdict(to: server, unasked: false, floor: 30)
        #expect(verdict == .connect(Self.sftpEndpoint))
    }

    // MARK: - A folder deleted since

    @Test("⌘[ into a folder deleted since skips it and lands on the one before")
    func backSkipsADeletedFolder() async throws {
        let (root, paths) = try Self.scratch(["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Self.pane(at: paths[0]).pane
        try await Self.visit(paths, in: pane)
        try FileManager.default.removeItem(atPath: paths[1].path)

        pane.goBack(nil)

        try await settleUntil { pane.panel.path == paths[0] && pane.tabs[0].history.walk == nil }
        #expect(pane.tabs[0].history.entries == [paths[0], paths[2]])
        #expect(pane.tabs[0].history.currentIndex == 0)
    }

    @Test(
        "a walk that fails for any other reason is reported, and the trail goes back to the screen"
    )
    func otherFailuresRevert() async throws {
        let (root, paths) = try Self.scratch(["a", "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Self.pane(at: paths[0]).pane
        try await Self.visit(paths, in: pane)
        _ = pane.tabs[0].history.back()

        let handled = pane.settleFailedWalk(after: VFSError.permissionDenied(paths[0]), inTab: 0)

        #expect(!handled)
        #expect(pane.tabs[0].history.currentPath == paths[1])
        #expect(pane.tabs[0].history.entries == paths)
    }

    @Test("a deleted folder picked from the ⌥↓ list is forgotten and still reported")
    func goneJumpIsReported() async throws {
        let (root, paths) = try Self.scratch(["a", "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = Self.pane(at: paths[0]).pane
        try await Self.visit(paths, in: pane)
        _ = pane.tabs[0].history.jump(to: 0)

        let handled = pane.settleFailedWalk(after: VFSError.notFound(paths[0]), inTab: 0)

        #expect(!handled)
        #expect(pane.tabs[0].history.entries == [paths[1]])
    }

    // MARK: - Closing and reopening

    @Test("a closed tab goes to the host whole, and reopening puts the same tab back in its place")
    func closedTabRoundTrips() async throws {
        let (root, paths) = try Self.scratch(["a", "b", "c"])
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = Self.pane(at: paths[0])
        let (pane, host) = (hosted.pane, hosted.host)
        // A pane whose view never loads lists nothing on its own, so the first tab is navigated.
        try await Self.visit([paths[0]], in: pane)
        pane.openInNewTab(paths[1])
        try await settleUntil { pane.tabs[1].hasLoaded }
        try await Self.visit([paths[2]], in: pane)
        let closing = pane.tabs[1]

        #expect(pane.closeTab(at: 1))

        #expect(pane.tabs.map(\.panel.path) == [paths[0]])
        let handed = try #require(host.closedTabs.last)
        #expect(handed.tab === closing)
        #expect(handed.index == 1)
        #expect(handed.tab.history.entries == [paths[1], paths[2]])

        pane.reopen(handed.tab, atSlot: handed.index)

        #expect(pane.tabs.count == 2)
        #expect(pane.tabs[1] === closing)
        #expect(pane.activeTabIndex == 1)
        #expect(pane.canGoBack)
    }

    @Test("the last tab is not closed, so nothing is handed over")
    func lastTabIsNotHandedOver() throws {
        let (root, paths) = try Self.scratch(["a"])
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = Self.pane(at: paths[0])
        let (pane, host) = (hosted.pane, hosted.host)
        #expect(!pane.closeTab(at: 0))
        #expect(host.closedTabs.isEmpty)
    }

    @Test("a tab closed partway through a walk reopens settled on the folder it was showing")
    func closedMidWalkSettles() async throws {
        let (root, paths) = try Self.scratch(["a", "b"])
        defer { try? FileManager.default.removeItem(at: root) }
        let hosted = Self.pane(at: paths[0])
        let (pane, host) = (hosted.pane, hosted.host)
        try await Self.visit(paths, in: pane)
        pane.openInNewTab(paths[0])
        try await settleUntil { pane.tabs[1].hasLoaded }
        _ = pane.tabs[0].history.back() // a walk in the background tab that never lands

        #expect(pane.closeTab(at: 0))

        let handed = try #require(host.closedTabs.last)
        #expect(handed.tab.history.walk == nil)
        #expect(handed.tab.history.currentPath == paths[1])
    }

    /// The menu half of ⇧⌘T. Driven live through File ▸ Reopen Closed Tab and the key itself; what
    /// is pinned here is that the item sits beside Close Tab, carries ⇧⌘T, goes to the window (whose
    /// closed tabs they are), and that nothing else in the menu bar claims the same key.
    @Test("File ▸ Reopen Closed Tab sits after Close Tab on ⇧⌘T, and nothing else has that key")
    func reopenMenuItem() throws {
        let menu = MainMenuBuilder.build(
            bindings: KeyBindingStore(defaults: ScratchDefaults.fresh())
        )
        let items = Self.flatten(menu)
        let reopen = try #require(items.first {
            $0.action == #selector(BrowserWindowController.reopenClosedTab(_:))
        })
        #expect(reopen.keyEquivalent == "t")
        #expect(reopen.keyEquivalentModifierMask == [.command, .shift])
        let file = try #require(reopen.menu)
        let close = try #require(file.items.firstIndex {
            $0.action == #selector(PanelViewController.closeCurrentTab(_:))
        })
        #expect(file.index(of: reopen) == close + 1)
        let sameKey = items.filter {
            $0.keyEquivalent.lowercased() == "t"
                && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                == [.command, .shift]
        }
        #expect(sameKey.count == 1)
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }
}
