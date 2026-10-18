import Testing

@testable import Dirnex

/// A second unlock of a vault that is still unlocking joins the first instead of running its own
/// `hdiutil attach` — which, probed, fails with "Resource temporarily unavailable" while the first one
/// mounts, so a double-click on a locked vault opened it and raised "couldn't be unlocked" over it.
@MainActor
@Suite("Vault unlocks in flight")
struct VaultUnlocksInFlightTests {
    @Test("a second request joins the unlock under way, and both are answered by it")
    func secondRequestJoins() {
        let unlocks = VaultUnlocksInFlight()
        var answers: [String] = []
        #expect(unlocks.join("/v.sparsebundle") { answers.append("first \($0)") })
        // The double-click's second half: told not to start an attach of its own.
        #expect(!unlocks.join("/v.sparsebundle") { answers.append("second \($0)") })
        #expect(answers.isEmpty)

        unlocks.settle("/v.sparsebundle", mountedAt: "/Volumes/V")
        #expect(answers == ["first /Volumes/V", "second /Volumes/V"])
    }

    @Test("a cancelled or failed unlock answers no one, and the next request starts afresh")
    func failureDropsEveryWaiter() {
        let unlocks = VaultUnlocksInFlight()
        var answered = false
        #expect(unlocks.join("/v.sparsebundle") { _ in answered = true })
        #expect(!unlocks.join("/v.sparsebundle") { _ in answered = true })

        unlocks.settle("/v.sparsebundle", mountedAt: nil)
        #expect(!answered)
        // Without this the vault could never be unlocked again: every later click would join an
        // unlock that is never coming.
        #expect(unlocks.join("/v.sparsebundle") { _ in })
    }

    @Test("two vaults unlock independently")
    func vaultsDoNotShare() {
        let unlocks = VaultUnlocksInFlight()
        var answers: [String] = []
        #expect(unlocks.join("/a.sparsebundle") { answers.append($0) })
        #expect(unlocks.join("/b.sparsebundle") { answers.append($0) })

        unlocks.settle("/b.sparsebundle", mountedAt: "/Volumes/B")
        #expect(answers == ["/Volumes/B"])
        // `a` is still unlocking.
        #expect(!unlocks.join("/a.sparsebundle") { answers.append($0) })
    }

    @Test("a waiter that unlocks again starts a new unlock rather than joining the settled one")
    func settledEntryIsGoneBeforeWaitersRun() {
        let unlocks = VaultUnlocksInFlight()
        var rejoined: Bool?
        #expect(unlocks.join("/v.sparsebundle") { _ in
            rejoined = unlocks.join("/v.sparsebundle") { _ in }
        })
        unlocks.settle("/v.sparsebundle", mountedAt: "/Volumes/V")
        #expect(rejoined == true)
    }
}
