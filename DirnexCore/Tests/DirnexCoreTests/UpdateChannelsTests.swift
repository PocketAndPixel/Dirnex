import Foundation
import Testing

@testable import DirnexCore

@Suite("UpdateChannels")
struct UpdateChannelsTests {
    @Test("opting out allows no extra channels — Sparkle sees only the default stable feed")
    func optedOutIsEmpty() {
        #expect(UpdateChannels.allowed(receiveBetaUpdates: false).isEmpty)
    }

    @Test("opting in allows exactly the beta channel")
    func optedInIsBeta() {
        #expect(UpdateChannels.allowed(receiveBetaUpdates: true) == ["beta"])
    }

    @Test("the beta identifier is the token the appcast tags beta items with")
    func betaIdentifierMatchesAppcastTag() {
        // The release pipeline stamps <sparkle:channel>beta</sparkle:channel> onto beta items; this
        // is the same literal the updater opts into, so a rename on one side can't silently strand
        // the other. Pinned so the shared token stays "beta".
        #expect(UpdateChannels.beta == "beta")
        #expect(UpdateChannels.allowed(receiveBetaUpdates: true).contains(UpdateChannels.beta))
    }
}
