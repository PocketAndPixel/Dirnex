import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Two panes for the suites that move tabs between them, in windows of their own on a stub backend:
/// the left on tabs alpha, beta and gamma, showing gamma, and the right on its one tab. Both save their
/// tabs into the scratch domain, under keys of this instance's own, since suites run side by side.
@MainActor
struct TabMovePanes {
    static let alpha = VFSPath.local("/tmp/dirnex-tab-moves/alpha")
    static let beta = VFSPath.local("/tmp/dirnex-tab-moves/beta")
    static let gamma = VFSPath.local("/tmp/dirnex-tab-moves/gamma")
    static let other = VFSPath.local("/tmp/dirnex-tab-moves/other")
    static let marked = Handoff.local("/tmp/dirnex-tab-moves/gamma/marked.txt")
    static let plain = Handoff.local("/tmp/dirnex-tab-moves/gamma/plain.txt")

    let left: WindowedPane
    let right: WindowedPane
    private let leftKey: String
    private let rightKey: String

    var leftPaths: [VFSPath] { left.pane.tabs.map(\.panel.path) }
    var rightPaths: [VFSPath] { right.pane.tabs.map(\.panel.path) }

    static func make() async throws -> TabMovePanes {
        let backend = Handoff.StubBackend(listings: [gamma: [marked, plain]])
        let left = windowedPane(at: alpha, backend: backend)
        let right = windowedPane(at: other, backend: backend)
        left.host.counterpart = right.pane
        right.host.counterpart = left.pane
        left.host.paneOnTheRight = right.pane
        right.host.paneOnTheLeft = left.pane
        let id = UUID().uuidString
        let leftKey = "tab-moves-left-\(id)"
        let rightKey = "tab-moves-right-\(id)"
        for (pane, key) in [(left.pane, leftKey), (right.pane, rightKey)] {
            pane.tabStateDefaults = TabStateScratch.defaults
            pane.restorationKey = key
        }
        try await settleUntil { left.pane.tabs[0].hasLoaded && right.pane.tabs[0].hasLoaded }
        // One at a time: opening a tab supersedes the listing still in flight for the one before.
        left.pane.openInNewTab(beta)
        try await settleUntil { left.pane.tabs[1].hasLoaded }
        left.pane.openInNewTab(gamma)
        try await settleUntil { left.pane.tabs[2].hasLoaded }
        left.window.layoutIfNeeded()
        right.window.layoutIfNeeded()
        return TabMovePanes(left: left, right: right, leftKey: leftKey, rightKey: rightKey)
    }

    func savedLeft() throws -> PersistedPane {
        try Self.saved(leftKey)
    }

    func savedRight() throws -> PersistedPane {
        try Self.saved(rightKey)
    }

    private static func saved(_ key: String) throws -> PersistedPane {
        try #require(TabPersistence.load(paneKey: key, from: TabStateScratch.defaults))
    }

    static func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }
}
