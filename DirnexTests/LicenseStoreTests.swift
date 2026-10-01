import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Holding a key (PLAN.md §M29 Slice 3): which keys a build accepts, and what it keeps.
@Suite("License store")
@MainActor
struct LicenseStoreTests {
    private static func day(_ text: String) throws -> LicenseDay {
        try #require(LicenseDay(text))
    }

    @Test("what this helper signs is what the test verifier accepts")
    func helperMatchesTestKey() throws {
        let key = try LicenseVerifier.test.check(TestLicenseKeys.key(to: "Zoë Groß")).get()
        #expect(key.licensee == "Zoë Groß")
        #expect(key.until == (try Self.day("2027-09-29")))
    }

    @Test("a Debug build accepts a key signed with the test key")
    func debugAcceptsTestKey() throws {
        #expect(LicensingSwitch.isDebugBuild)
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let key = try store.activate(TestLicenseKeys.key()).get()
        #expect(key.licensee == "Jane Appleseed")
        #expect(store.key == key)
        #expect(store.status == .licensed(key))
    }

    @Test("a release build's verifiers refuse it: only the production key counts")
    func releaseRefusesTestKey() throws {
        let store = LicenseStore(
            defaults: ScratchDefaults.fresh(),
            verifiers: [.production],
            buildReleaseDay: nil
        )
        #expect(try store.activate(TestLicenseKeys.key()) == .failure(.badSignature))
        #expect(store.key == nil)
    }

    @Test("the key is kept, and read back at the next launch")
    func survivesRelaunch() throws {
        let defaults = ScratchDefaults.fresh()
        let key = try LicenseStore(defaults: defaults, buildReleaseDay: nil).activate(
            TestLicenseKeys.key()
        ).get()
        let relaunched = LicenseStore(defaults: defaults, buildReleaseDay: nil)
        #expect(relaunched.key == key)
    }

    @Test("a kept key this build doesn't accept counts for nothing, and is left where it was")
    func storedKeyIsCheckedAgain() throws {
        let defaults = ScratchDefaults.fresh()
        let text = try TestLicenseKeys.key()
        try LicenseStore(defaults: defaults, verifiers: [.test], buildReleaseDay: nil).activate(text).get(
        )
        let release = LicenseStore(
            defaults: defaults,
            verifiers: [.production],
            buildReleaseDay: nil
        )
        #expect(release.key == nil)
        #expect(release.status == .unlicensed)
        #expect(defaults.string(forKey: AppPreferences.Keys.licenseKey) == text)
    }

    @Test("Remove forgets the key")
    func remove() throws {
        let defaults = ScratchDefaults.fresh()
        let store = LicenseStore(defaults: defaults, buildReleaseDay: nil)
        try store.activate(TestLicenseKeys.key()).get()
        store.remove()
        #expect(store.key == nil)
        #expect(defaults.string(forKey: AppPreferences.Keys.licenseKey) == nil)
        #expect(LicenseStore(defaults: defaults, buildReleaseDay: nil).key == nil)
    }

    @Test("a refused key leaves the one held in place")
    func refusalKeepsHeldKey() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let held = try store.activate(TestLicenseKeys.key()).get()
        #expect(store.activate("dnx1.garbage.garbage") == .failure(.malformed))
        #expect(store.key == held)
    }

    @Test("a newer key replaces the one held")
    func renewalReplaces() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        try store.activate(TestLicenseKeys.key(until: "2027-03-12")).get()
        let renewed = try store.activate(TestLicenseKeys.key(until: "2028-03-12")).get()
        #expect(store.key == renewed)
    }

    @Test("a key is lapsed for a build released after its end, and licensed up to it")
    func coverageOfThisBuild() throws {
        let text = try TestLicenseKeys.key(until: "2027-03-12")
        let onTheDay = LicenseStore(
            defaults: ScratchDefaults.fresh("a"),
            buildReleaseDay: try Self.day("2027-03-12")
        )
        let dayAfter = LicenseStore(
            defaults: ScratchDefaults.fresh("b"),
            buildReleaseDay: try Self.day("2027-03-13")
        )
        let key = try onTheDay.activate(text).get()
        try dayAfter.activate(text).get()
        #expect(onTheDay.status == .licensed(key))
        #expect(dayAfter.status == .lapsed(key))
    }

    @Test("a change is announced; a refusal or the same key again is not")
    func announcesChanges() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: LicenseStore.didChange,
            object: store,
            queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        let text = try TestLicenseKeys.key()
        store.activate(text)
        store.activate(text)
        store.activate("not a key")
        store.remove()
        #expect(counter.count == 2)
    }

    @Test("a pasted activation link activates the key inside it")
    func pastedLink() throws {
        let store = LicenseStore(defaults: ScratchDefaults.fresh(), buildReleaseDay: nil)
        let text = try TestLicenseKeys.key()
        let pasted = "https://dirnex.app/activate#\(text.prefix(70))\n\(text.dropFirst(70))"
        let key = try store.activate(LicenseLinks.keyText(fromPasted: pasted)).get()
        #expect(key.text == text)
    }
}

@MainActor
private final class NotificationCounter {
    var count = 0
}
