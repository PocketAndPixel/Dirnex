import Foundation
import Testing

@testable import DirnexCore

/// Which saved vault a pin on a locked vault's volume is in. Reported 2026-11-17: picking such a pin
/// asked the NAS for a share named after the vault's volume, while the pin's mark showed the vault.
@Suite("A pin in a locked vault")
struct PinnedVaultTests {
    private static let documents = VaultLocation(
        imagePath: "/Users/u/Documents/Documents.sparsebundle",
        volumeName: "Documents"
    )
    private static let taxes = VaultLocation(imagePath: "/Users/u/Taxes.dmg", volumeName: "Taxes")
    private static let work = VFSPath.local("/Volumes/Documents/Work")
    private static let server = SMBLocation(host: "nas", username: "u")

    private static func vault(
        _ entry: FavoriteEntry,
        volume: String = "Documents",
        among vaults: [VaultLocation] = [taxes, documents]
    ) -> VaultLocation? {
        PinnedVault.vault(for: entry, volume: volume, among: vaults)
    }

    @Test("a pin on a saved vault's volume is in that vault")
    func vaultOfTheVolume() {
        #expect(Self.vault(FavoriteEntry(name: "Docs", path: Self.work)) == Self.documents)
        #expect(
            Self.vault(FavoriteEntry(path: .local("/Volumes/Taxes")), volume: "Taxes") == Self.taxes
        )
    }

    @Test("a volume no saved vault is called is in none, and a name is matched whole")
    func unknownVolume() {
        let pin = FavoriteEntry(path: Self.work)
        #expect(Self.vault(pin, among: [Self.taxes]) == nil)
        #expect(Self.vault(pin, among: []) == nil)
        #expect(Self.vault(FavoriteEntry(path: .local("/Volumes/Doc/Work")), volume: "Doc") == nil)
    }

    @Test("a pin that recorded its share is on that share, whatever vault has the volume's name")
    func recordedShareWins() {
        let pin = FavoriteEntry(
            path: Self.work,
            endpoint: .smb(Self.server.share(named: "Documents"))
        )
        #expect(Self.vault(pin) == nil)
    }

    /// A server with no share says nothing about where the pin is, as it does not for a share
    /// (`PinnedShareTests.shareLessEndpointIsNotAnAnswer`).
    @Test("a recorded server that names no share does not keep a pin out of its vault")
    func shareLessServerIsNoAnswer() {
        let pin = FavoriteEntry(path: Self.work, endpoint: .smb(Self.server))
        #expect(Self.vault(pin) == Self.documents)
    }

    @Test("of two vaults with one volume name, the first in sidebar order")
    func firstInSidebarOrder() {
        let copy = VaultLocation(imagePath: "/Users/u/Copy.sparsebundle", volumeName: "Documents")
        let pin = FavoriteEntry(path: Self.work)
        #expect(Self.vault(pin, among: [copy, Self.documents]) == copy)
        #expect(Self.vault(pin, among: [Self.documents, copy]) == Self.documents)
    }

    /// The mark and the pick are two readings of one pin, and the bug was the two disagreeing: the
    /// padlock in the sidebar, and a pick that went to the NAS.
    @Test("a pick goes into a vault exactly when the pin's mark says it is in one")
    func pickAgreesWithTheMark() {
        let mounts = [MountTableEntry(mountPoint: "/", isLocal: true)]
        let vaults = [Self.taxes, Self.documents]
        let pins = [
            FavoriteEntry(path: Self.work),
            FavoriteEntry(path: .local("/Volumes/Documents")),
            FavoriteEntry(path: .local("/Volumes/Taxes/2026")),
            FavoriteEntry(path: Self.work, endpoint: .smb(Self.server.share(named: "Documents"))),
            FavoriteEntry(path: Self.work, endpoint: .smb(Self.server)),
            FavoriteEntry(path: .local("/Volumes/USB/Photos")),
            FavoriteEntry(path: .local("/Users/u/Documents/Work"))
        ]
        for pin in pins {
            let marked = LocationSource.ofPin(
                pin,
                mounts: mounts,
                vaultMountPoints: [],
                vaultVolumeNames: vaults.map(\.volumeName),
                home: "/Users/u",
                isInternalVolume: { $0 == "/" },
                isSymlink: { _ in false }
            ) == .vault
            let picked = PinnedShare.unmountedVolume(
                of: pin.path,
                mounted: mounts,
                isSymlink: { _ in false }
            )
            .flatMap { PinnedVault.vault(for: pin, volume: $0, among: vaults) } != nil
            #expect(
                marked == picked,
                "\(pin.path.path), endpoint \(String(describing: pin.serverEndpoint))"
            )
        }
    }
}
