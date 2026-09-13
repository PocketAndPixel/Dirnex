import AppKit
import Testing

@testable import Dirnex

/// ⌘1–⌘9 on a dialog's tabs, the numbers shown while ⌘ is held, and the tab selector's focus ring.
///
/// The key half is driven through ``TabShortcuts/perform(_:in:)`` with a real `NSEvent`, which is
/// everything the monitor does once it has established the window is key — something a test host's
/// windows never are. The badge half lays a real `NSTabView` out and reads the badges it gains.
@Suite("Tab shortcuts", .serialized)
@MainActor
struct TabShortcutsTests {
    private final class PaneKeyController: NSWindowController, PaneKeyWindowController {}

    private struct Fixture {
        let window: NSWindow
        let tabs: NSTabView
        /// Held here because a window does not retain its controller.
        let controller: NSWindowController?
    }

    private func fixture(tabs count: Int = 3, controller: NSWindowController? = nil) -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let tabs = NSTabView(frame: NSRect(x: 20, y: 20, width: 460, height: 260))
        for label in ["General", "Permissions", "Sharing", "Attributes"].prefix(count) {
            let item = NSTabViewItem()
            item.label = label
            item.view = NSView()
            tabs.addTabViewItem(item)
        }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        content.addSubview(tabs)
        window.contentView = content
        controller?.window = window
        window.layoutIfNeeded()
        tabs.display()
        return Fixture(window: window, tabs: tabs, controller: controller)
    }

    private func key(
        _ characters: String,
        code: UInt16,
        _ modifiers: NSEvent.ModifierFlags = .command,
        in window: NSWindow? = nil
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    // MARK: - Which number

    @Test("⌘ with a digit names that tab, by character or by the digit key's code")
    func numbersFromDigits() throws {
        #expect(TabShortcuts.tabNumber(for: try key("2", code: 19)) == 2)
        #expect(TabShortcuts.tabNumber(for: try key("9", code: 25)) == 9)
        // AZERTY: the 2 key types é, and ⌘ does not change that.
        #expect(TabShortcuts.tabNumber(for: try key("é", code: 19)) == 2)
    }

    @Test("no ⌘, another modifier with it, or a digit outside 1–9 names no tab")
    func notATabNumber() throws {
        #expect(TabShortcuts.tabNumber(for: try key("2", code: 19, [])) == nil)
        #expect(TabShortcuts.tabNumber(for: try key("2", code: 19, [.command, .shift])) == nil)
        #expect(TabShortcuts.tabNumber(for: try key("2", code: 19, [.command, .option])) == nil)
        #expect(TabShortcuts.tabNumber(for: try key("0", code: 29)) == nil)
        #expect(TabShortcuts.tabNumber(for: try key("c", code: 8)) == nil)
    }

    // MARK: - Picking a tab

    @Test("⌘2 picks the second tab and is swallowed")
    func commandTwoPicksTheSecondTab() throws {
        let fixture = fixture()
        #expect(TabShortcuts.perform(try key("2", code: 19), in: fixture.window))
        #expect(fixture.tabs.indexOfTabViewItem(try #require(fixture.tabs.selectedTabViewItem)) == 1)
    }

    @Test("a number past the last tab is swallowed too, and changes nothing")
    func pastTheLastTabIsClaimed() throws {
        let fixture = fixture(tabs: 3)
        var refused = 0
        let saved = TabShortcuts.refuse
        defer { TabShortcuts.refuse = saved }
        TabShortcuts.refuse = { refused += 1 }

        #expect(TabShortcuts.perform(try key("7", code: 26), in: fixture.window))
        #expect(refused == 1)
        #expect(fixture.tabs.indexOfTabViewItem(try #require(fixture.tabs.selectedTabViewItem)) == 0)
    }

    @Test("the browser window's keys are left alone, and so is a window with no tabs")
    func onlyDialogsWithTabs() throws {
        let browser = fixture(controller: PaneKeyController())
        #expect(!TabShortcuts.perform(try key("2", code: 19), in: browser.window))

        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        plain.isReleasedWhenClosed = false
        plain.contentView = NSView()
        #expect(!TabShortcuts.perform(try key("2", code: 19), in: plain))
    }

    // MARK: - The numbers

    @Test("holding ⌘ puts 1, 2, 3 on the tabs, each at its own tab, and letting go takes them away")
    func numbersSitOnTheirTabs() throws {
        let fixture = fixture(tabs: 3)
        let rects = TabNumberBadge.tabRects(in: fixture.tabs)
        try #require(rects.count == 3)

        TabShortcuts.showNumbers(on: fixture.tabs)
        let badges = fixture.tabs.subviews.compactMap { $0 as? TabNumberBadge }
        #expect(badges.map(\.number) == [1, 2, 3])
        for (badge, tab) in zip(badges, rects) {
            #expect(badge.frame.midX > tab.minX && badge.frame.midX < tab.maxX)
            #expect(TabNumberBadge.room(in: fixture.tabs).contains(badge.frame))
        }

        TabShortcuts.hideNumbers()
        #expect(!fixture.tabs.subviews.contains { $0 is TabNumberBadge })
    }

    @Test("a badge with no room above its tab moves down, never out of sight")
    func badgeStaysInsideItsRoom() {
        let tab = NSRect(x: 100, y: 5, width: 70, height: 24)
        let open = TabNumberBadge.frame(
            forTab: tab,
            in: NSRect(x: 0, y: -40, width: 400, height: 300),
            flipped: true
        )
        #expect(open.midY == tab.minY)
        let tight = TabNumberBadge.frame(
            forTab: tab,
            in: NSRect(x: 0, y: 6, width: 400, height: 300),
            flipped: true
        )
        #expect(tight.minY == 6)
    }

    // MARK: - The selector's ring

    @Test(
        "the selector's focus ring is drawn a gap clear of the tab, and an absent ring stays absent"
    )
    func ringIsWidened() {
        let gap = TabSelectorFocusRing.gap
        let tab = NSRect(x: 135, y: 5, width: 74, height: 24)
        #expect(TabSelectorFocusRing.widened(tab) == tab.insetBy(dx: -gap, dy: -gap))
        #expect(TabSelectorFocusRing.widened(.zero) == .zero)
    }
}
