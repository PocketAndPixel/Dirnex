import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Where licensing shows (PLAN.md §M29 "lands dormant"): nowhere without the switch, and in the
/// App menu, the palette and the `dirnex://` link with it. The test host is a Debug build, which
/// shows it.
@Suite("Licensing surfaces")
@MainActor
struct LicensingSurfaceTests {
    // MARK: - The switch

    @Test("a release build shows licensing only when Info.plist carries a true switch")
    func releaseRule() {
        for off: Any? in [nil, false, "YES", "true", NSNumber(value: false)] {
            #expect(
                !LicensingSwitch.isOn(infoValue: off, isDebugBuild: false),
                "\(String(describing: off))"
            )
        }
        #expect(LicensingSwitch.isOn(infoValue: true, isDebugBuild: false))
        #expect(LicensingSwitch.isOn(infoValue: NSNumber(value: true), isDebugBuild: false))
    }

    @Test("a Debug build shows licensing whatever Info.plist says")
    func debugRule() {
        #expect(LicensingSwitch.isOn(infoValue: nil, isDebugBuild: true))
        #expect(LicensingSwitch.isDebugBuild)
        #expect(LicensingSwitch.isOn)
    }

    @Test("without the switch the licensing commands leave the registry, and nothing else does")
    func switchedOffRegistry() {
        let all = CommandCatalog.all
        let off = LicensingSwitch.available(all, isOn: false)
        #expect(Set(all.map(\.id)).subtracting(off.map(\.id)) == CommandCatalog.licensingCommandIDs)
        #expect(LicensingSwitch.available(all, isOn: true).map(\.id) == all.map(\.id))
    }

    @Test("an undated build: the test host carries no release date")
    func undatedBuild() {
        #expect(LicensingSwitch.buildReleaseDay == nil)
    }

    // MARK: - With the switch on

    @Test("both commands are in the palette's catalog and wired to an action")
    func commandsAreReachable() {
        for id in CommandCatalog.licensingCommandIDs {
            #expect(LocalizedCatalog.command(for: id) != nil, "\(id)")
            #expect(CommandBinding.selector(for: id) != nil, "\(id)")
        }
    }

    @Test("the App menu lists License… and Buy a License… right after Check for Updates…")
    func appMenuOrder() throws {
        let appMenu = try #require(MainMenuBuilder.build().items.first?.submenu)
        let actions = appMenu.items.map(\.action)
        let updates = try #require(
            actions.firstIndex(of: #selector(AppDelegate.checkForUpdates(_:)))
        )
        #expect(actions[updates + 1] == #selector(AppDelegate.showLicense(_:)))
        #expect(actions[updates + 2] == #selector(AppDelegate.buyLicense(_:)))
        #expect(appMenu.items[updates + 3].isSeparatorItem)
    }

    // MARK: - The link

    @Test("a link that isn't the activation link is not handled")
    func otherLinksIgnored() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        for link in ["dirnex://settings", "https://dirnex.app/activate#abc", "file:///tmp/a.txt"] {
            let url = try #require(URL(string: link))
            #expect(!LicenseLinkActivation.handle(url, store: store, over: nil), "\(link)")
        }
    }

    @Test("without the switch even the activation link is ignored")
    func linkIgnoredWhenOff() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let url = try #require(URL(string: "dirnex://license?key=\(TestLicenseKeys.key())"))
        #expect(!LicenseLinkActivation.handle(url, store: store, over: nil, isOn: false))
        #expect(store.key == nil)
    }

    @Test("the confirmation names who the key is for and until when, and Escape cancels")
    func confirmation() throws {
        let key = try LicenseVerifier.test.check(
            TestLicenseKeys.key(to: "Zoë Groß", until: "2027-03-12")
        ).get()
        let alert = LicenseLinkActivation.confirmationAlert(for: key, replacing: nil)
        #expect(alert.messageText.contains("Zoë Groß"))
        #expect(alert.informativeText.contains(key.until.displayText))
        #expect(alert.buttons.count == 2)
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.keyEquivalent == "\u{1b}")
    }

    @Test("replacing a key, the confirmation names the license it replaces")
    func confirmationWhenReplacing() throws {
        let key = try LicenseVerifier.test.check(TestLicenseKeys.key(to: "New Owner")).get()
        let current = try LicenseVerifier.test.check(TestLicenseKeys.key(to: "Old Owner")).get()
        let alert = LicenseLinkActivation.confirmationAlert(for: key, replacing: current)
        #expect(alert.informativeText.contains("Old Owner"))
        let fresh = LicenseLinkActivation.confirmationAlert(for: key, replacing: nil)
        #expect(!fresh.informativeText.contains("Old Owner"))
    }

    @Test("a refused link says why, in the License tab's words, with one button")
    func refusal() {
        for error in LicenseKeyError.allCases {
            let alert = LicenseLinkActivation.refusalAlert(for: error)
            #expect(alert.informativeText == error.message)
            #expect(alert.buttons.count == 1)
        }
    }

    @Test("every refusal has its own message")
    func distinctMessages() {
        let messages = LicenseKeyError.allCases.map(\.message)
        #expect(Set(messages).count == messages.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }
}
