import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where Report a Bug… shows (PLAN.md §M30 "Hidden until the endpoint exists"): nowhere in a build
/// without `DirnexBugReportURL`, and the Help menu around it either way.
@Suite("Bug report surfaces")
@MainActor
struct BugReportSurfaceTests {
    // MARK: - The switch

    @Test("Info.plist must name an https address; only a Debug argument may name this Mac over http")
    func switchRule() {
        let https = "https://dirnex.app/api/bug-reports"
        let local = "http://127.0.0.1:9555/api/bug-reports"
        #expect(BugReportSwitch.endpoint(infoValue: https, debugValue: nil)?.absoluteString == https)
        #expect(BugReportSwitch.endpoint(infoValue: "", debugValue: nil) == nil)
        #expect(BugReportSwitch.endpoint(infoValue: nil, debugValue: nil) == nil)
        #expect(BugReportSwitch.endpoint(infoValue: local, debugValue: nil) == nil)
        #expect(BugReportSwitch.endpoint(infoValue: "", debugValue: local)?.absoluteString == local)
        #expect(
            BugReportSwitch.endpoint(infoValue: https, debugValue: local)?.absoluteString == local
        )
        #expect(
            BugReportSwitch.endpoint(infoValue: https, debugValue: "http://example.com/x")?.absoluteString == https
        )
    }

    @Test("the test host carries the key empty, so it has nowhere to send a report")
    func testHostIsOff() {
        let value = Bundle.main.object(forInfoDictionaryKey: BugReportSwitch.infoPlistKey) as? String
        #expect(value?.isEmpty == true)
        #expect(BugReportSwitch.endpoint == nil)
        #expect(!BugReportSwitch.isOn)
    }

    @Test("without an address Report a Bug… leaves the registry, and nothing else does")
    func switchedOffRegistry() {
        let all = CommandCatalog.all
        let off = BugReportSwitch.available(all, isOn: false)
        #expect(Set(all.map(\.id)).subtracting(off.map(\.id)) == CommandCatalog.bugReportCommandIDs)
        #expect(BugReportSwitch.available(all, isOn: true).map(\.id) == all.map(\.id))
        #expect(!AvailableCommands.all.contains { $0.id == "help.reportBug" })
        #expect(LocalizedCatalog.command(for: "help.reportBug") == nil)
    }

    @Test("all three Help commands are wired to an action")
    func commandsAreBound() {
        for id in ["help.reportBug", "help.website", "help.releaseNotes"] {
            #expect(CommandBinding.selector(for: id) != nil, "\(id)")
        }
        #expect(LocalizedCatalog.command(for: "help.website") != nil)
        #expect(LocalizedCatalog.command(for: "help.releaseNotes") != nil)
    }

    // MARK: - The Help menu

    @Test(
        "the Help menu is last, is AppKit's help menu, and holds the two links with no stray separator"
    )
    func helpMenu() throws {
        let menu = MainMenuBuilder.build()
        let help = try #require(menu.items.last?.submenu)
        #expect(NSApp.helpMenu === help)
        #expect(help.title == CommandCategory.help.localizedTitle)
        let actions = help.items.map(\.action)
        #expect(
            actions == [
                #selector(AppDelegate.openWebsite(_:)),
                #selector(AppDelegate.openReleaseNotes(_:))
            ]
        )
        #expect(!help.items.contains { $0.isSeparatorItem })
    }

    @Test("a separator that separates nothing is dropped, and one between items stays")
    func straySeparators() {
        let menu = NSMenu()
        menu.addItem(.separator())
        menu.addItem(withTitle: "A", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(.separator())
        menu.addItem(withTitle: "B", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        MainMenuBuilder.removeStraySeparators(from: menu)
        #expect(menu.items.map { $0.isSeparatorItem ? "-" : $0.title } == ["A", "-", "B"])
    }
}
