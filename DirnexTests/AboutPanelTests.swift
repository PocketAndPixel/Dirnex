import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The About panel's lines and the Acknowledgments window. Every check reads dates, links and
/// structure rather than English, because the test host runs in whatever language the developer
/// pinned Dirnex to.
@Suite("About panel")
@MainActor
struct AboutPanelTests {
    private static func day(_ text: String) throws -> LicenseDay {
        try #require(LicenseDay(text))
    }

    private static func key(to name: String = "Jane Appleseed", until: String) throws -> LicenseKey {
        try LicenseVerifier.test.check(TestLicenseKeys.key(to: name, until: until)).get()
    }

    // MARK: - The lines

    @Test("an undated build has no release line; a dated one names its day, with no link")
    func releaseLine() throws {
        let today = try Self.day("2027-01-01")
        #expect(AboutPanel.lines(releaseDay: nil, license: nil, today: today).count == 1)

        let released = try Self.day("2026-10-14")
        let lines = AboutPanel.lines(releaseDay: released, license: nil, today: today)
        #expect(lines.count == 2)
        let line = try #require(lines.first)
        #expect(line.count == 1)
        #expect(line[0].text.contains(AboutPanel.dayText(released)))
        #expect(!AboutPanel.dayText(released).contains(" "), "a wrap must never split the date")
        #expect(line[0].link == nil)
    }

    @Test("a build that shows nothing about licenses has no license line")
    func noLicenseLineWhenOff() throws {
        let lines = AboutPanel.lines(
            releaseDay: nil,
            license: nil,
            today: try Self.day("2027-01-01")
        )
        #expect(lines.flatMap { $0 }.compactMap(\.link) == [
            HelpLinks.website, AcknowledgmentsWindowController.link
        ])
    }

    @Test("the last line links to dirnex.app and to the acknowledgments")
    func linksLine() throws {
        let lines = AboutPanel.lines(
            releaseDay: nil,
            license: .unlicensed,
            today: try Self.day("2027-01-01")
        )
        let last = try #require(lines.last)
        #expect(last.compactMap(\.link) == [HelpLinks.website, AcknowledgmentsWindowController.link])
        #expect(last.first?.text == "dirnex.app")
        #expect(last.last?.text == AcknowledgmentsWindowController.title)
    }

    @Test("no license: one link, to the store")
    func unlicensed() throws {
        let line = try licenseLine(.unlicensed, today: "2027-01-01")
        #expect(line.compactMap(\.link) == [LicenseLinks.buy])
    }

    @Test("a license still running: its end day, and no link")
    func licensed() throws {
        let key = try Self.key(until: "2027-09-29")
        for today in ["2027-01-01", "2027-09-29"] {
            let line = try licenseLine(.licensed(key), today: today)
            #expect(line.count == 1, "\(today)")
            #expect(line[0].text.contains(AboutPanel.dayText(key.until)), "\(today)")
            #expect(line[0].link == nil, "\(today)")
        }
    }

    @Test("a license whose updates ended, still covering this version: the day, and Renew")
    func licensedButEnded() throws {
        let key = try Self.key(until: "2027-09-29")
        let line = try licenseLine(.licensed(key), today: "2027-09-30")
        #expect(line.first?.text.contains(AboutPanel.dayText(key.until)) == true)
        #expect(line.compactMap(\.link) == [LicenseLinks.renew(key)])
    }

    @Test("a license that doesn't cover this version: Renew, and a different sentence")
    func lapsed() throws {
        let key = try Self.key(until: "2027-09-29")
        let line = try licenseLine(.lapsed(key), today: "2027-10-30")
        #expect(line.compactMap(\.link) == [LicenseLinks.renew(key)])
        let ended = try licenseLine(.licensed(key), today: "2027-10-30")
        #expect(line.first?.text != ended.first?.text)
    }

    @Test("no line ever names who the license is for, nor puts it in a link")
    func neverNamesTheLicensee() throws {
        let name = "jane.appleseed@example.com"
        let key = try Self.key(to: name, until: "2027-09-29")
        for (status, today) in [
            (LicenseStatus.licensed(key), "2027-01-01"),
            (.licensed(key), "2027-12-01"),
            (.lapsed(key), "2027-12-01")
        ] {
            let lines = AboutPanel.lines(
                releaseDay: try Self.day("2027-01-01"),
                license: status,
                today: try Self.day(today)
            )
            for piece in lines.flatMap({ $0 }) {
                #expect(!piece.text.contains(name))
                #expect(piece.link?.absoluteString.contains("appleseed") != true)
            }
        }
    }

    private func licenseLine(_ status: LicenseStatus, today: String) throws -> AboutPanel.Line {
        let lines = AboutPanel.lines(releaseDay: nil, license: status, today: try Self.day(today))
        #expect(lines.count == 2)
        return try #require(lines.first)
    }

    // MARK: - The credits

    @Test(
        "the credits carry each link on its own text, and draw in a color that follows the appearance"
    )
    func credits() throws {
        let key = try Self.key(until: "2027-09-29")
        let lines = AboutPanel.lines(
            releaseDay: try Self.day("2026-10-14"),
            license: .lapsed(key),
            today: try Self.day("2027-10-30")
        )
        let credits = AboutPanel.credits(lines)
        #expect(credits.string == lines.map { $0.map(\.text).joined() }.joined(separator: "\n"))

        var linked: [String: URL] = [:]
        let whole = NSRange(location: 0, length: credits.length)
        credits.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let url = value as? URL else { return }
            linked[(credits.string as NSString).substring(with: range)] = url
        }
        let pieces = lines.flatMap { $0 }.filter { $0.link != nil }
        #expect(linked == Dictionary(uniqueKeysWithValues: pieces.map { ($0.text, $0.link!) }))
        #expect(
            credits.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor
        )
    }

    @Test("App menu ▸ About opens this panel, not the plain one")
    func menuItem() throws {
        let appMenu = try #require(MainMenuBuilder.build().items.first?.submenu)
        #expect(appMenu.items.first?.action == #selector(AppDelegate.showAbout(_:)))
    }

    // MARK: - Acknowledgments

    @Test("the acknowledgments link is recognized in any case, and nothing else is")
    func acknowledgmentsLink() throws {
        for link in [
            "dirnex://acknowledgments",
            "DIRNEX://Acknowledgments",
            "dirnex://acknowledgments/"
        ] {
            #expect(
                AcknowledgmentsWindowController.isLink(try #require(URL(string: link))),
                "\(link)"
            )
        }
        for link in [
            "dirnex://license?key=abc", "dirnex://acknowledgments/more", "https://acknowledgments",
            "dirnex://settings"
        ] {
            #expect(
                !AcknowledgmentsWindowController.isLink(try #require(URL(string: link))),
                "\(link)"
            )
        }
        #expect(AcknowledgmentsWindowController.isLink(AcknowledgmentsWindowController.link))
    }

    @Test("the license link's handler leaves the acknowledgments link alone")
    func licenseHandlerIgnoresIt() {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        #expect(
            !LicenseLinkActivation.handle(
                AcknowledgmentsWindowController.link,
                store: store,
                over: nil
            )
        )
    }

    @Test("the app carries NOTICE and LICENSE, and the window shows both")
    func bundledFiles() throws {
        for name in AcknowledgmentsWindowController.files {
            #expect(Bundle.main.url(forResource: name, withExtension: nil) != nil, "\(name)")
        }
        let text = try #require(AcknowledgmentsWindowController.text())
        #expect(text.contains("THIRD-PARTY COMPONENTS"))
        #expect(text.contains("Apache License"))
        #expect(AcknowledgmentsWindowController.shared.textView.string == text)
        #expect(AcknowledgmentsWindowController.text(in: Bundle(for: BundleMarker.self)) == nil)
    }

    @Test("NOTICE names every package the project links and the bundled helper")
    func noticeNamesEveryComponent() throws {
        let notice = try String(
            contentsOf: try #require(Bundle.main.url(forResource: "NOTICE", withExtension: nil)),
            encoding: .utf8
        )
        let project = try String(contentsOf: Self.repoRoot.appending(
            path: "Dirnex.xcodeproj/project.pbxproj"
        ), encoding: .utf8)
        let packages = project.matches(of: /XCRemoteSwiftPackageReference "([^"]+)" \*\/ = \{/)
            .map { String($0.output.1) }
        #expect(
            Set(packages) == ["SwiftTerm", "Sparkle"],
            "a new package needs its license in NOTICE"
        )
        for name in packages + ["gpr_tools"] {
            #expect(notice.contains(name), "\(name)")
        }
    }

    /// The repository, two folders up from this file.
    private static let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent(
    )
}

/// A class that lives in the test bundle, which carries no NOTICE.
private final class BundleMarker {}
