import Foundation
import Testing

@testable import DirnexCore

/// The user's saved vault list: its identity rule (one vault is one *resolved* path) and its order,
/// which is the sidebar's order. Its own suite rather than a section of `VaultTests`, because a
/// stored list is a different thing from the `hdiutil` argument-and-output handling that file covers
/// — and `VaultTests` rides the 250-line type-body ceiling.
@Suite("SavedVaults")
struct SavedVaultsTests {
    @Test("one vault is one resolved path, whichever spelling it arrives in")
    func savedVaultsAreKeyedByResolvedPath() {
        // A `mutating` call cannot sit inside `#expect` (docs/NOTES.md), so every result is hoisted.
        var saved = SavedVaults()
        let addedFirst = saved.add(VaultLocation(imagePath: "/tmp/v.sparsebundle", volumeName: "V"))
        #expect(addedFirst)
        // The same vault under macOS's other spelling for the same directory: an update, not a
        // second row — otherwise it would also file a second Keychain item for one passphrase.
        let updated = saved.add(
            VaultLocation(imagePath: "/private/tmp/v.sparsebundle", volumeName: "V2")
        )
        #expect(updated)
        #expect(saved.vaults.count == 1)
        #expect(saved.vaults[0].volumeName == "V2")
        // Re-adding the identical record reports no change, so nothing writes or rebuilds.
        let unchanged = saved.add(
            VaultLocation(imagePath: "/private/tmp/v.sparsebundle", volumeName: "V2")
        )
        #expect(!unchanged)
        // A *re-spelled* path is a change even though it is the same vault: identity is the resolved
        // path, but the record keeps the spelling the user last reached it by, which is what the
        // sidebar shows and what a click navigates to.
        let respelled = saved.add(VaultLocation(imagePath: "/tmp/v.sparsebundle", volumeName: "V2"))
        #expect(respelled)
        #expect(saved.vaults.count == 1)
        #expect(saved.vaults[0].imagePath == "/tmp/v.sparsebundle")

        saved.add(VaultLocation(imagePath: "/vaults/work.sparsebundle", volumeName: "Work"))
        #expect(saved.vaults.count == 2)
        #expect(saved.vault(atPath: "/private/tmp/v.sparsebundle")?.volumeName == "V2")
        let removed = saved.remove(imagePath: "/private/tmp/v.sparsebundle")
        #expect(removed)
        let removedAgain = saved.remove(imagePath: "/tmp/v.sparsebundle")
        #expect(!removedAgain)
        #expect(saved.vaults.map(\.volumeName) == ["Work"])

        // Order is the sidebar's order and survives a round trip through the store's JSON.
        var many = SavedVaults()
        for name in ["a", "b", "c"] {
            many.add(VaultLocation(imagePath: "/v/\(name).sparsebundle", volumeName: name))
        }
        let data = try? JSONEncoder().encode(many)
        let decoded = data.flatMap { try? JSONDecoder().decode(SavedVaults.self, from: $0) }
        #expect(decoded?.vaults.map(\.volumeName) == ["a", "b", "c"])
    }

    @Test("move reorders with array semantics, and leaves the paths alone")
    func moveReordersVaults() {
        var saved = SavedVaults(vaults: ["a", "b", "c"].map {
            VaultLocation(imagePath: "/v/\($0).sparsebundle", volumeName: $0)
        })
        saved.move(from: 0, to: 2)
        #expect(saved.vaults.map(\.volumeName) == ["b", "c", "a"])
        saved.move(from: 2, to: 0)
        #expect(saved.vaults.map(\.volumeName) == ["a", "b", "c"])
        // Out of range is ignored rather than trapping: the sidebar maps table rows onto these
        // indices, and a stale row must not take the app down.
        saved.move(from: 5, to: 0)
        saved.move(from: 0, to: 99)
        #expect(saved.vaults.map(\.volumeName) == ["b", "c", "a"])
        // Reordering is *only* reordering — the addressing every Keychain lookup and mount
        // comparison is keyed on is untouched.
        #expect(saved.vaults.map(\.imagePath) == [
            "/v/b.sparsebundle", "/v/c.sparsebundle", "/v/a.sparsebundle"
        ])
    }
}
