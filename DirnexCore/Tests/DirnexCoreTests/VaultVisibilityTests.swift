import Foundation
import Testing

@testable import DirnexCore

/// Finder visibility for an unlocked vault: the attach flag, the live remount, and the rule that
/// keeps a shown vault out of the sidebar's Volumes section.
///
/// The answer is one app-wide preference (**Settings ▸ General ▸ Show unlocked vaults in Finder**,
/// default on) rather than a flag on each vault, so nothing here reads a stored value — every
/// function below is handed the answer, which is what makes all of it testable.
@Suite("Vault visibility")
struct VaultVisibilityTests {
    // MARK: - Attaching

    @Test("the attach flag is the whole difference, and it is never inferred")
    func attachVisibility() {
        #expect(
            DiskImageArguments.attach(atPath: "/v/P.sparsebundle", showingInFinder: false)
                .contains("-nobrowse")
        )

        let shown = DiskImageArguments.attach(atPath: "/v/P.sparsebundle", showingInFinder: true)
        #expect(!shown.contains("-nobrowse"))
        // Everything else about the command is unchanged — in particular the passphrase still comes
        // off stdin, which is the one property this file must not be able to weaken.
        #expect(shown.contains("-stdinpass"))
        #expect(shown.contains("-plist"))
        #expect(shown.first == "attach")
        #expect(shown.last == "/v/P.sparsebundle")
    }

    // MARK: - Remounting a vault that is already open

    /// The real flags word measured on a Dirnex-attached vault, so the assertions below are about
    /// what macOS actually reports rather than about a hand-made set:
    /// `nosuid,nodev,local,dontbrowse,ignore-ownership,journaled`.
    private let asAttached = MountFlags(rawValue: 0x04B0_9218)

    @Test("showing an open vault re-states every option, not just the browse bit")
    func remountToVisible() {
        let remount = DiskVolumeArguments.remount(
            mountPoint: "/Volumes/Personal",
            flags: asAttached,
            showingInFinder: true
        )
        #expect(
            remount == .arguments(["-u", "-o", "browse,nosuid,nodev,noowners", "/Volumes/Personal"])
        )
    }

    @Test("noowners is carried across, because a bare remount was measured to drop it")
    func remountPreservesIgnoreOwnership() {
        // The negative control for the note in `DiskVolumeArguments.remount`: `-o browse` alone took
        // 0x04B09218 to 0x04809218 on a live volume, i.e. it cleared MNT_IGNORE_OWNERSHIP as well as
        // MNT_DONTBROWSE. Every file in the vault would then be owned by a uid from whichever Mac
        // wrote it. If this assertion ever goes, that is what broke.
        guard case let .arguments(argv) = DiskVolumeArguments.remount(
            mountPoint: "/Volumes/Personal",
            flags: asAttached,
            showingInFinder: true
        ) else {
            Issue.record("expected a remount to be possible")
            return
        }
        let options = argv[2].split(separator: ",").map(String.init)
        #expect(options.contains("noowners"))
        #expect(options.contains("nosuid"))
        #expect(options.contains("nodev"))
        // `local` and `journaled` describe the file system rather than the mount request, so they
        // have no `-o` spelling and must not be invented.
        #expect(!options.contains("local"))
        #expect(!options.contains("journaled"))
    }

    @Test("hiding it again is the same operation with the bit the other way")
    func remountToHidden() {
        var visible = asAttached
        visible.remove(.doNotBrowse)
        let remount = DiskVolumeArguments.remount(
            mountPoint: "/Volumes/Personal",
            flags: visible,
            showingInFinder: false
        )
        #expect(
            remount == .arguments(
                ["-u", "-o", "nobrowse,nosuid,nodev,noowners", "/Volumes/Personal"]
            )
        )
    }

    @Test("a volume already in the asked-for state spawns nothing")
    func remountUnnecessary() {
        var visible = asAttached
        visible.remove(.doNotBrowse)
        #expect(
            DiskVolumeArguments.remount(
                mountPoint: "/Volumes/P", flags: asAttached, showingInFinder: false
            ) == .unnecessary
        )
        #expect(
            DiskVolumeArguments.remount(
                mountPoint: "/Volumes/P", flags: visible, showingInFinder: true
            ) == .unnecessary
        )
    }

    @Test("a read-only vault is left alone and told to wait for the next unlock")
    func remountReadOnly() {
        // Measured: `mount -u` on a read-only volume is "Permission denied", exit 66, with the flags
        // word byte-identical afterwards. So there is nothing to attempt — the setting is saved and
        // the next attach honors it.
        let readOnly = MountFlags(rawValue: 0x04B0_9219)
        #expect(readOnly.contains(.readOnly))
        #expect(
            DiskVolumeArguments.remount(
                mountPoint: "/Volumes/P", flags: readOnly, showingInFinder: true
            ) == .takesEffectOnNextUnlock
        )
        // Even so, "already as asked" still wins: a read-only volume that is *already* visible needs
        // no excuse made for it.
        var readOnlyVisible = readOnly
        readOnlyVisible.remove(.doNotBrowse)
        #expect(
            DiskVolumeArguments.remount(
                mountPoint: "/Volumes/P", flags: readOnlyVisible, showingInFinder: true
            ) == .unnecessary
        )
    }

    // MARK: - One row, one section

    @Test("a shown vault does not also appear under Volumes")
    func vaultVolumeIsNotListedTwice() {
        // Verified against the live app before this rule existed: turning the setting on made
        // `/Volumes/SecDocs` come back from `FileManager.mountedVolumeURLs(options:
        // [.skipHiddenVolumes])`, which `-nobrowse` had been keeping out. The duplicate row is worse
        // than untidy — it carries a plain eject button that detaches the image without evicting the
        // panes standing inside it or dropping what `VaultPrivacy` must forget.
        let volumes = [
            volume(named: "Macintosh HD", at: "/", isRoot: true),
            volume(named: "SecDocs", at: "/Volumes/SecDocs"),
            volume(named: "Backup", at: "/Volumes/Backup")
        ]
        let filtered = SidebarLocations.hidingVaults(
            in: volumes,
            mountedAt: ["/Volumes/SecDocs"]
        )
        #expect(filtered.map(\.name) == ["Macintosh HD", "Backup"])
    }

    @Test("with no vault unlocked the volume list is untouched")
    func noVaultsChangesNothing() {
        let volumes = [volume(named: "Backup", at: "/Volumes/Backup")]
        #expect(SidebarLocations.hidingVaults(in: volumes, mountedAt: []) == volumes)
        // A *locked* vault contributes no mount point, so its image sitting on a volume in the list
        // must not remove that volume — the filter matches mount points, never image paths.
        #expect(
            SidebarLocations.hidingVaults(
                in: volumes, mountedAt: ["/Volumes/Other"]
            ) == volumes
        )
    }

    private func volume(named name: String, at path: String, isRoot: Bool = false) -> MountedVolume {
        MountedVolume(
            name: name,
            path: .local(path),
            isRoot: isRoot,
            isRemovable: false,
            isEjectable: !isRoot,
            isInternal: isRoot,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
    }

    // MARK: - Persistence

    @Test("a vault saved while the setting was per-vault still loads, retired key and all")
    func decodesRetiredKeyJSON() throws {
        // Both shapes anybody has on disk: the original two-field one, and the one written while
        // `showsInFinder` was a property of the vault. `JSONDecoder` ignores a key no property
        // claims, so the retired one costs nothing — which is the *opposite* of the case that made
        // this type decode by hand in the first place (a synthesized decoder throws on a key that is
        // **missing**, and `SavedVaults` is read through a `try?`, so the whole Vaults section would
        // have emptied on first launch after that update).
        let stored = Data("""
        {"vaults":[
          {"imagePath":"/v/Personal.sparsebundle","volumeName":"Personal"},
          {"imagePath":"/v/Work.sparsebundle","volumeName":"Work","showsInFinder":true}
        ]}
        """.utf8)
        let saved = try JSONDecoder().decode(SavedVaults.self, from: stored)
        #expect(saved.vaults.map(\.volumeName) == ["Personal", "Work"])
        #expect(saved.vaults.map(\.imagePath) == [
            "/v/Personal.sparsebundle", "/v/Work.sparsebundle"
        ])
    }

    @Test("a vault round-trips, and carries no settings of its own")
    func roundTrip() throws {
        let saved = SavedVaults(vaults: [
            VaultLocation(imagePath: "/v/A.sparsebundle", volumeName: "A"),
            VaultLocation(imagePath: "/v/B.sparsebundle", volumeName: "B")
        ])
        let encoded = try JSONEncoder().encode(saved)
        #expect(try JSONDecoder().decode(SavedVaults.self, from: encoded) == saved)
        // Nothing about visibility is written any more: one preference is the whole answer, so a
        // saved vault cannot disagree with it. Asserted on the bytes, since the round trip above is
        // true whatever extra fields ride along.
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        #expect(!text.isEmpty)
        #expect(!text.contains("showsInFinder"))
    }
}
