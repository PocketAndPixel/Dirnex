import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A vault that will not lock because it is in use names whatever is using it (2026-11-19), as the
/// sidebar's Eject does (`EjectFailureTests`). The probe runs for real here, against the volume this
/// test host's own binary is on.
@Suite("Vault lock failure: who is using the vault")
struct VaultLockFailureTests {
    let inUse = VaultError.volumeInUse(name: "Secret")

    @Test("one name is in the sentence, with the vault's")
    func oneName() {
        let detail = VaultLockFailure.detail(for: inUse, users: ["VLC"])
        #expect(detail.contains("VLC"))
        #expect(detail.contains("Secret"))
        #expect(detail != LocalizedCatalog.sentence(for: inUse))
    }

    @Test("several names are all in the sentence")
    func severalNames() {
        let detail = VaultLockFailure.detail(for: inUse, users: ["VLC", "Terminal"])
        #expect(detail.contains("VLC"))
        #expect(detail.contains("Terminal"))
        #expect(detail.contains("Secret"))
        #expect(detail != VaultLockFailure.detail(for: inUse, users: ["VLC"]))
    }

    @Test("with nobody to name, the in-use sentence is the one it always was")
    func noName() {
        #expect(
            VaultLockFailure.detail(for: inUse, users: []) == LocalizedCatalog.sentence(for: inUse)
        )
    }

    @Test("any other vault failure keeps its own sentence")
    func otherFailure() {
        #expect(
            VaultLockFailure.detail(for: .couldNotLock, users: ["VLC"])
                == LocalizedCatalog.sentence(for: .couldNotLock)
        )
    }

    @Test("a failure that is not about use asks nobody, and one that is not a vault's is a lock's")
    func onlyInUseAsks() {
        // The host itself is on this volume, so a probe here would name it.
        let path = Bundle.main.bundlePath
        let other = VaultLockFailure(reading: VaultError.couldNotLock, mountPoint: path)
        #expect(other == VaultLockFailure(error: .couldNotLock, users: []))
        let foreign = VaultLockFailure(reading: CocoaError(.fileReadUnknown), mountPoint: path)
        #expect(foreign == VaultLockFailure(error: .couldNotLock, users: []))
    }

    @Test("a vault in use is asked who is using it")
    func inUseAsks() throws {
        let me = try #require(NSRunningApplication.current.localizedName)
        let failure = VaultLockFailure(reading: inUse, mountPoint: Bundle.main.bundlePath)
        #expect(failure.error == inUse)
        #expect(failure.users.contains(me))
    }
}
