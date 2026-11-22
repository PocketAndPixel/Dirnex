import AppKit
import DirnexCore
import Foundation
import Sparkle
import SwiftUI
import Testing

@testable import Dirnex

/// A key whose license this build's list revoked, or whose renewal it took back (PLAN.md §M40 Slice
/// 7): what the store keeps and refuses, and what Settings ▸ License, the reminder, the update notice
/// and the About panel make of it. The list's own rules are pinned in the core.
@Suite("Revoked license keys")
@MainActor
struct LicenseRevocationAppTests {
    /// The id `TestLicenseKeys.key()` signs by default, and another one the signer wrote.
    private static let id = "5RSU7LEVTH3C46PCOBVL54R57M"
    private static let otherID = "KKAG24PTKXBC7ZMCPL35MRTZSE"

    private static let revoked = LicenseRevocations([.license(id)])

    private static func day(_ text: String) throws -> LicenseDay {
        try #require(LicenseDay(text))
    }

    private func makeStore(
        _ defaults: UserDefaults,
        revocations: LicenseRevocations,
        buildReleaseDay: String? = nil
    ) -> LicenseStore {
        LicenseStore(
            defaults: defaults,
            verifiers: [.test],
            revocations: revocations,
            buildReleaseDay: buildReleaseDay.flatMap(LicenseDay.init)
        )
    }

    // MARK: - The store

    @Test("a kept key whose license is revoked is held, counts for nothing, and stays stored")
    func storedKeyIsRevoked() throws {
        let defaults = ScratchDefaults.fresh()
        let text = try TestLicenseKeys.key()
        let key = try makeStore(defaults, revocations: .none).activate(text).get()

        let relaunched = makeStore(defaults, revocations: Self.revoked)
        #expect(relaunched.heldKey == key)
        #expect(relaunched.key == nil)
        #expect(relaunched.status == .revoked(key))
        #expect(defaults.string(forKey: AppPreferences.Keys.licenseKey) == text)

        // A build whose list no longer names it counts it again.
        #expect(makeStore(defaults, revocations: .none).status == .licensed(key))
    }

    @Test("a revoked key pasted is refused, and the key held stays, unannounced")
    func pastedRevokedKeyIsRefused() throws {
        let defaults = ScratchDefaults.fresh()
        let store = makeStore(defaults, revocations: LicenseRevocations([.license(Self.otherID)]))
        let heldText = try TestLicenseKeys.key()
        let held = try store.activate(heldText).get()

        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: LicenseStore.didChange,
            object: store,
            queue: nil
        ) { _ in MainActor.assumeIsolated { counter.posts += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        let revokedText = try TestLicenseKeys.key(to: "Someone Else", id: Self.otherID)
        #expect(store.check(revokedText) == .failure(.revoked))
        #expect(store.activate(revokedText) == .failure(.revoked))
        #expect(store.key == held)
        #expect(defaults.string(forKey: AppPreferences.Keys.licenseKey) == heldText)
        #expect(counter.posts == 0)
    }

    @Test("a key that doesn't verify is refused for that, whatever id it names")
    func signatureComesFirst() throws {
        let release = LicenseStore(
            defaults: ScratchDefaults.fresh(),
            verifiers: [.production],
            revocations: Self.revoked,
            buildReleaseDay: nil
        )
        #expect(try release.check(TestLicenseKeys.key()) == .failure(.invalid(.badSignature)))
    }

    @Test("a key whose renewal was taken back ends on the day the license was put back to")
    func renewalTakenBack() throws {
        let list = LicenseRevocations([.renewal(Self.id, until: "2027-09-29")])
        let defaults = ScratchDefaults.fresh()
        let text = try TestLicenseKeys.key(until: "2028-09-29")
        let store = makeStore(defaults, revocations: list, buildReleaseDay: "2028-01-01")

        let key = try store.activate(text).get()
        #expect(key.until == (try Self.day("2027-09-29")))
        // What's kept is the key the email holds, so a later list without the line restores its year.
        #expect(defaults.string(forKey: AppPreferences.Keys.licenseKey) == text)
        #expect(store.status == .lapsed(key))
        #expect(store.key == key)
        #expect(store.status.reminderVariant == .renew(until: try Self.day("2027-09-29")))

        let earlier = makeStore(defaults, revocations: list, buildReleaseDay: "2027-06-01")
        #expect(earlier.status == .licensed(key))
        // The same key pasted again is the one held: nothing to announce or replace.
        #expect(store.check(text) == .success(key))
    }

    // MARK: - What the rest of the app makes of it

    @Test("the reminder treats a revoked key as no key at all")
    func reminderSeesNoKey() throws {
        let defaults = ScratchDefaults.fresh("store")
        _ = try makeStore(defaults, revocations: .none).activate(TestLicenseKeys.key()).get()
        let now = Date(timeIntervalSince1970: 1_799_564_400)
        let records = ScratchDefaults.fresh("records")
        records.set(
            now.addingTimeInterval(-31 * 24 * 60 * 60),
            forKey: AppPreferences.Keys.licenseGraceStart
        )

        func dueVariant(_ revocations: LicenseRevocations) -> LicenseReminderVariant? {
            LicenseReminderController(
                isEnabled: true,
                store: makeStore(defaults, revocations: revocations),
                records: LicenseReminderRecords(defaults: records),
                clock: { now },
                realClock: { now }
            ).dueVariant
        }
        #expect(dueVariant(Self.revoked) == .buy)
        #expect(dueVariant(.none) == nil)
    }

    @Test("an update holds nothing back for a revoked key, as for no key")
    func updateNoticeSeesNoKey() throws {
        func updater(_ revocations: LicenseRevocations, _ name: String) throws -> AppUpdater {
            // Kept before the list names it: a key pasted while its license is revoked is refused.
            let defaults = ScratchDefaults.fresh(name, function: "updateNoticeSeesNoKey")
            _ = try makeStore(defaults, revocations: .none).activate(
                TestLicenseKeys.key(until: "2027-03-12")
            ).get()
            let store = makeStore(defaults, revocations: revocations, buildReleaseDay: "2027-02-01")
            #expect(store.heldKey != nil)
            return AppUpdater(licenseStore: store, licensingIsOn: true)
        }
        let released = try Self.day("2027-04-01").date(in: .gmt)
        // The control: the same key, not revoked, holds the update back.
        #expect(throws: (any Error).self) {
            try updater(.none, "control").gate(
                version: "1.4.0",
                build: "50",
                releaseDate: released,
                check: .updates
            )
        }
        let revoked = try updater(Self.revoked, "revoked")
        try revoked.gate(version: "1.4.0", build: "50", releaseDate: released, check: .updates)
        #expect(revoked.pendingCoverageNotice == nil)
    }

    @Test("the About panel's line for a revoked key is the line for no key")
    func aboutLine() throws {
        let key = try LicenseVerifier.test.check(TestLicenseKeys.key()).get()
        let today = try Self.day("2027-01-01")
        let revoked = AboutPanel.lines(releaseDay: nil, license: .revoked(key), today: today)
        let unlicensed = AboutPanel.lines(releaseDay: nil, license: .unlicensed, today: today)
        #expect(revoked == unlicensed)
    }

    // MARK: - Settings ▸ License

    /// The real tab over `store`, in a window of its own.
    private func licenseTab(_ store: LicenseStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LicenseSettingsView(store: store))
        return window
    }

    private func buttonTitles(in root: NSView?) -> [String] {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return root.map(all)?.compactMap { ($0 as? NSButton)?.title } ?? []
    }

    /// The titles of the tab's buttons once it has drawn them. Its text can't be read back: SwiftUI
    /// builds no accessibility tree in the test host, even with the window on screen (seen
    /// 2026-11-19), so the words were checked in the running app. The buttons tell the four states
    /// apart: Buy alone with no key, Remove and Renew with one, and Remove and Buy only when revoked.
    private func buttons(over store: LicenseStore) async throws -> [String] {
        let window = licenseTab(store)
        defer { window.close() }
        let remove = String(localized: "Remove License")
        var titles: [String] = []
        try await settleUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            titles = buttonTitles(in: window.contentView)
            return titles.contains(remove)
        }
        return titles
    }

    @Test("the tab offers Remove and Buy for a revoked license, and no Renew")
    func settingsTab() async throws {
        let defaults = ScratchDefaults.fresh()
        _ = try makeStore(defaults, revocations: .none).activate(TestLicenseKeys.key()).get()
        let titles = try await buttons(over: makeStore(defaults, revocations: Self.revoked))
        #expect(titles.contains(String(localized: "Buy a License…")))
        #expect(!titles.contains(String(localized: "Renew…")))
    }

    @Test("negative control: the same key, not revoked, offers Renew and no Buy")
    func settingsTabControl() async throws {
        let defaults = ScratchDefaults.fresh()
        _ = try makeStore(defaults, revocations: .none).activate(TestLicenseKeys.key()).get()
        let titles = try await buttons(over: makeStore(defaults, revocations: .none))
        #expect(titles.contains(String(localized: "Renew…")))
        #expect(!titles.contains(String(localized: "Buy a License…")))
    }
}

@MainActor
private final class Counter {
    var posts = 0
}
