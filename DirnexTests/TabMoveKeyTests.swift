import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Moving tabs from the keyboard: ⌥⌘[ and ⌥⌘] along a strip and on round both panes, and ⇧⌘M
/// straight to the other pane.
@MainActor
@Suite("Moving tabs from the keyboard", .serialized)
struct TabMoveKeyTests {
    private typealias Panes = TabMovePanes

    @Test("⌥⌘[ and ⌥⌘] step the showing tab along the strip, and are saved")
    func stepAlongTheStrip() async throws {
        let panes = try await Panes.make()
        let pane = panes.left.pane
        let left = #selector(PanelViewController.moveTabLeft(_:))
        let right = #selector(PanelViewController.moveTabRight(_:))
        pane.selectTab(at: 1)

        pane.moveTabLeft(nil)
        #expect(panes.leftPaths == [Panes.beta, Panes.alpha, Panes.gamma])
        #expect(pane.panel.path == Panes.beta)
        #expect(
            pane.validateMenuItem(Panes.menuItem(left)),
            "the next step goes round into the right pane"
        )

        pane.moveTabRight(nil)
        pane.moveTabRight(nil)
        #expect(panes.leftPaths == [Panes.alpha, Panes.gamma, Panes.beta])
        #expect(pane.panel.path == Panes.beta)
        #expect(
            pane.validateMenuItem(Panes.menuItem(right)),
            "the next step crosses to the right pane"
        )
        #expect(pane.validateMenuItem(Panes.menuItem(left)))

        // Saved as it changes, not only on the way down.
        let persisted = try panes.savedLeft()
        #expect(
            persisted.tabs.map(\.path).map(VFSPath.local) == [Panes.alpha, Panes.gamma, Panes.beta]
        )
        #expect(persisted.activeIndex == 2)
    }

    @Test(
        "⌥⌘] off the strip's end enters the right pane at its start, shows there and takes the focus"
    )
    func stepAcrossToTheRight() async throws {
        let panes = try await Panes.make()
        let moving = panes.left.pane.tabs[2]
        moving.panel.setSelection([Panes.marked.path])

        panes.left.pane.moveTabRight(nil)

        #expect(panes.leftPaths == [Panes.alpha, Panes.beta])
        #expect(panes.left.pane.panel.path == Panes.beta)
        #expect(panes.rightPaths == [Panes.gamma, Panes.other])
        #expect(panes.right.pane.activeTabIndex == 0)
        // The same tab, so what is its own comes along: here, its marks.
        #expect(panes.right.pane.tabs[0] === moving)
        #expect(panes.right.pane.panel.selection == [Panes.marked.path])
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)

        #expect(
            try panes.savedLeft().tabs.map(\.path).map(VFSPath.local) == [Panes.alpha, Panes.beta]
        )
        let right = try panes.savedRight()
        #expect(right.tabs.map(\.path).map(VFSPath.local) == [Panes.gamma, Panes.other])
        #expect(right.activeIndex == 0)
    }

    @Test("⌥⌘[ off the strip's start enters the left pane at its end, where the tab had come from")
    func stepAcrossAndBack() async throws {
        let panes = try await Panes.make()
        panes.left.pane.moveTabRight(nil)
        #expect(panes.rightPaths == [Panes.gamma, Panes.other])

        panes.right.pane.moveTabLeft(nil)

        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
        #expect(panes.left.pane.activeTabIndex == 2)
        #expect(panes.left.pane.panel.path == Panes.gamma)
        #expect(panes.rightPaths == [Panes.other])
        #expect(panes.left.window.firstResponder === panes.left.pane.tableView)
    }

    /// The step after a crossing belongs to the pane it landed in, which is who the menu asks now.
    @Test("steps carry on along the far strip and round into the left pane at its start")
    func stepOnRoundToTheStart() async throws {
        let panes = try await Panes.make()
        let right = #selector(PanelViewController.moveTabRight(_:))
        panes.left.pane.moveTabRight(nil)
        #expect(panes.right.pane.validateMenuItem(Panes.menuItem(right)))

        panes.right.pane.moveTabRight(nil)
        #expect(panes.rightPaths == [Panes.other, Panes.gamma])
        #expect(panes.right.pane.activeTabIndex == 1)
        #expect(
            panes.right.pane.validateMenuItem(Panes.menuItem(right)),
            "the next step goes round into the left pane"
        )

        panes.right.pane.moveTabRight(nil)
        #expect(panes.rightPaths == [Panes.other])
        #expect(panes.leftPaths == [Panes.gamma, Panes.alpha, Panes.beta])
        #expect(panes.left.pane.activeTabIndex == 0)
        #expect(panes.left.window.firstResponder === panes.left.pane.tableView)
    }

    @Test("⌥⌘[ off the left pane's start goes round into the right pane at its end, and ⌥⌘] back")
    func stepRoundToTheEnd() async throws {
        let panes = try await Panes.make()
        panes.left.pane.selectTab(at: 0)

        panes.left.pane.moveTabLeft(nil)
        #expect(panes.leftPaths == [Panes.beta, Panes.gamma])
        #expect(panes.rightPaths == [Panes.other, Panes.alpha])
        #expect(panes.right.pane.activeTabIndex == 1)
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)
        let right = try panes.savedRight()
        #expect(right.tabs.map(\.path).map(VFSPath.local) == [Panes.other, Panes.alpha])
        #expect(right.activeIndex == 1)

        panes.right.pane.moveTabRight(nil)
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
        #expect(panes.left.pane.activeTabIndex == 0)
        #expect(panes.rightPaths == [Panes.other])
    }

    @Test("a pane's last tab stays when a step would take it across, either way")
    func stepKeepsTheLastTab() async throws {
        let panes = try await Panes.make()
        let left = #selector(PanelViewController.moveTabLeft(_:))
        let right = #selector(PanelViewController.moveTabRight(_:))
        #expect(!panes.right.pane.validateMenuItem(Panes.menuItem(left)))
        #expect(!panes.right.pane.validateMenuItem(Panes.menuItem(right)))

        panes.right.pane.moveTabLeft(nil)
        panes.right.pane.moveTabRight(nil)

        #expect(panes.rightPaths == [Panes.other])
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
    }

    @Test("⇧⌘M moves the showing tab beside the other pane's, shows it there and takes the focus")
    func sendToTheOtherPane() async throws {
        let panes = try await Panes.make()
        let moving = panes.left.pane.tabs[2]
        moving.panel.setSelection([Panes.marked.path])

        panes.left.pane.moveTabToOtherPanel(nil)

        #expect(panes.leftPaths == [Panes.alpha, Panes.beta])
        #expect(panes.left.pane.panel.path == Panes.beta)
        #expect(panes.rightPaths == [Panes.other, Panes.gamma])
        #expect(panes.right.pane.activeTabIndex == 1)
        // The same tab, so what is its own comes along: here, its marks.
        #expect(panes.right.pane.tabs[1] === moving)
        #expect(panes.right.pane.panel.selection == [Panes.marked.path])
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)

        #expect(
            try panes.savedLeft().tabs.map(\.path).map(VFSPath.local) == [Panes.alpha, Panes.beta]
        )
        let right = try panes.savedRight()
        #expect(right.tabs.map(\.path).map(VFSPath.local) == [Panes.other, Panes.gamma])
        #expect(right.activeIndex == 1)
    }

    @Test("a pane's last tab stays, and Move Tab to Other Panel is unavailable there")
    func lastTabStays() async throws {
        let panes = try await Panes.make()
        let action = #selector(PanelViewController.moveTabToOtherPanel(_:))
        #expect(!panes.right.pane.validateMenuItem(Panes.menuItem(action)))
        #expect(panes.left.pane.validateMenuItem(Panes.menuItem(action)))

        panes.right.pane.moveTabToOtherPanel(nil)

        #expect(panes.rightPaths == [Panes.other])
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
    }

    @Test("the Window menu carries the three moves on ⌥⌘[, ⌥⌘] and ⇧⌘M")
    func windowMenuItems() throws {
        let menu = MainMenuBuilder.build(
            bindings: KeyBindingStore(defaults: ScratchDefaults.fresh())
        )
        let items = Self.flatten(menu)
        let expected: [Selector: KeyEquivalent] = [
            #selector(PanelViewController.moveTabLeft(_:)): KeyEquivalent(
                key: "[",
                mask: [.command, .option]
            ),
            #selector(PanelViewController.moveTabRight(_:)): KeyEquivalent(
                key: "]",
                mask: [.command, .option]
            ),
            #selector(PanelViewController.moveTabToOtherPanel(_:)): KeyEquivalent(
                key: "m",
                mask: [.command, .shift]
            )
        ]
        for (action, equivalent) in expected {
            let item = try #require(items.first { $0.action == action }, "\(action)")
            #expect(item.keyEquivalent == equivalent.key)
            #expect(item.keyEquivalentModifierMask == equivalent.mask)
        }
    }

    private struct KeyEquivalent {
        let key: String
        let mask: NSEvent.ModifierFlags
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(flatten) ?? []) }
    }
}
