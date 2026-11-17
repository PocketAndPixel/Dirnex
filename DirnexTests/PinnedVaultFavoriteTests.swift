import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A pin inside a vault that is locked (`PanelViewController+PinnedVault`). Reported 2026-11-17: picking
/// one asked the NAS for a share named after the vault's volume, and the NAS said it offered none.
///
/// The saved vaults and servers are handed in, since `VaultStore` and `ServerConnectionStore` are
/// `UserDefaults.standard`, the developer's own sidebar in a target that runs inside the app
/// (docs/NOTES.md ▸ Testing). A temporary folder stands in for the unlocked volume and `StubPanelHost`
/// for the window's unlock, so nothing reaches `hdiutil`, the Keychain or a server. The volume names
/// are made up, so nothing is mounted at them on any Mac.
@Suite("A pin in a locked vault")
@MainActor
struct PinnedVaultFavoriteTests {
    private static let volume = "pinned-vault-test-volume"
    private static let vault = VaultLocation(
        imagePath: "/private/tmp/pinned-vault-test.sparsebundle",
        volumeName: volume
    )
    private static let pin = FavoriteEntry(name: "Docs", path: .local("/Volumes/\(volume)/Work"))
    /// A saved server like the NAS row in the report, on a host that cannot resolve and with no
    /// password on file, so a regression that took the share route would try nothing.
    private static let nas = SMBLocation(host: "pinned-vault.invalid", username: "u")
    private static let server = ServerConnection(name: "SMB", endpoint: .smb(nas))

    /// A fixture of two folders, removed afterwards: an empty `Start` for the pane to open on, and
    /// `Volume`, laid out as the unlocked vault's volume with `Work` in it.
    private struct Fixture {
        let root: URL
        var start: VFSPath { .local(root.appendingPathComponent("Start").path) }
        var volume: String { root.appendingPathComponent("Volume").path }
        var work: VFSPath { .local(root.appendingPathComponent("Volume/Work").path) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("PinnedVault-\(UUID().uuidString)")
            for folder in ["Start", "Volume/Work"] {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
        }
    }

    /// The view is loaded up front, as a pane in a window has it: its first load activates the tab,
    /// which navigates to the start folder, and a landing's `focusTable()` would otherwise load it
    /// *after* the landing's navigation and send the pane back.
    ///
    /// The start folder is the fixture's empty one, not the temporary directory. A pane with a view
    /// asks the shared `RowIconLoader` for every row it lists, and hundreds of rows there crowded out
    /// `RowIconArrivalTests` running beside this suite, which counts that loader's loads.
    private static func pane(host: StubPanelHost, at start: VFSPath) -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: start,
            restorationKey: nil
        )
        pane.panel = Panel(path: start)
        pane.host = host
        pane.loadViewIfNeeded()
        return pane
    }

    // MARK: - Where a pick goes

    @Test("a pin on a locked vault's volume unlocks that vault, and no server is asked for a share")
    func lockedVaultIsUnlocked() {
        // The reported route: without the vault, the saved server would be asked for a share of
        // the vault's volume name.
        #expect(PanelViewController.sharesToMount(for: Self.pin, saved: [Self.server]) == [
            Self.nas.share(named: Self.volume)
        ])
        let route = PanelViewController.missingPinRoute(
            for: Self.pin,
            vaults: [Self.vault],
            servers: [Self.server]
        )
        #expect(route == .unlock(Self.vault))
    }

    @Test("a pin that recorded its share mounts the share, whatever vault has the volume's name")
    func recordedShareIsMounted() {
        let share = Self.nas.share(named: Self.volume)
        let pin = FavoriteEntry(name: "Docs", path: Self.pin.path, endpoint: .smb(share))
        let route = PanelViewController.missingPinRoute(
            for: pin,
            vaults: [Self.vault],
            servers: [Self.server]
        )
        #expect(route == .mount([share]))
    }

    @Test("with no vault of the volume's name, the saved servers are asked, and with none, unpin")
    func noVaultFallsBackToShares() {
        let other = VaultLocation(imagePath: "/private/tmp/other.sparsebundle", volumeName: "Other")
        #expect(PanelViewController.missingPinRoute(
            for: Self.pin,
            vaults: [other],
            servers: [Self.server]
        ) == .mount([Self.nas.share(named: Self.volume)]))
        #expect(
            PanelViewController.missingPinRoute(for: Self.pin, vaults: [other], servers: []) == .unpin
        )
    }

    @Test("a folder deleted from this Mac is not in a vault, whatever the vaults are called")
    func localFolderIsNotInAVault() {
        let users = VaultLocation(imagePath: "/private/tmp/users.sparsebundle", volumeName: "Users")
        let entry = FavoriteEntry(path: .local("/Users/pinned-vault-test-gone"))
        #expect(PanelViewController.missingPinRoute(
            for: entry,
            vaults: [users],
            servers: [Self.server]
        ) == .unpin)
    }

    // MARK: - Landing

    /// The pin was made on `/Volumes/<volume>` and the stand-in mounts elsewhere, so this also
    /// covers a vault that comes back at `/Volumes/<volume> 1`.
    @Test("the vault unlocks and the pane lands on the pinned folder, wherever the vault mounted")
    func landsInsideTheVault() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = StubPanelHost()
        host.vaultMountPoint = fixture.volume
        let pane = Self.pane(host: host, at: fixture.start)

        pane.openPinnedVault(Self.pin, in: Self.vault, inNewTab: false)

        #expect(host.vaultUnlockRequests == [Self.vault])
        try await settleUntil { pane.panel.path == fixture.work }
        #expect(pane.panel.path == fixture.work)
    }

    @Test("a pane that moved on while the vault unlocked stays where it went")
    func movedOnPaneStays() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let host = StubPanelHost()
        let pane = Self.pane(host: host, at: fixture.start)
        let elsewhere = VFSPath.local(fixture.volume)

        pane.openPinnedVault(Self.pin, in: Self.vault, inNewTab: false)
        pane.navigate(to: elsewhere)
        try await settleUntil { pane.panel.path == elsewhere }
        let token = pane.loadToken
        for answer in host.unansweredVaultUnlocks {
            answer(fixture.volume)
        }

        #expect(host.vaultUnlockRequests == [Self.vault])
        #expect(pane.loadToken == token, "the late unlock navigated the pane")
        #expect(pane.panel.path == elsewhere)
    }
}
