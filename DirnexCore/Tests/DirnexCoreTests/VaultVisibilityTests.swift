import Foundation
import Testing

@testable import DirnexCore

/// Per-vault Finder visibility: the attach flag, the live remount, and the migration that decides
/// whether anybody still has a Vaults section after the update.
@Suite("Vault visibility")
struct VaultVisibilityTests {
    // MARK: - Attaching

    @Test("a vault is private unless it was told otherwise, and silence means private")
    func attachVisibility() {
        // The default is the whole safety property: a call site that says nothing gets `-nobrowse`.
        #expect(DiskImageArguments.attach(atPath: "/v/P.sparsebundle").contains("-nobrowse"))
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

    @Test("a vault saved before this setting existed still loads")
    func decodesLegacyJSON() throws {
        // The trap this guards: `SavedVaults` is decoded through a `try?`, and a synthesized decoder
        // throws on a missing key regardless of the property's default. Without the hand-written
        // `init(from:)` this JSON — every vault anybody already has — decodes to *nothing*, the
        // sidebar's Vaults section empties on first launch after the update, and each vault's
        // Keychain item is orphaned. Nothing would log.
        let legacy = Data("""
        {"vaults":[{"imagePath":"/v/Personal.sparsebundle","volumeName":"Personal"}]}
        """.utf8)
        let saved = try JSONDecoder().decode(SavedVaults.self, from: legacy)
        #expect(saved.vaults.count == 1)
        #expect(saved.vaults.first?.volumeName == "Personal")
        #expect(saved.vaults.first?.showsInFinder == false)
    }

    @Test("the setting round-trips")
    func roundTrip() throws {
        let saved = SavedVaults(vaults: [
            VaultLocation(imagePath: "/v/A.sparsebundle", volumeName: "A", showsInFinder: true),
            VaultLocation(imagePath: "/v/B.sparsebundle", volumeName: "B")
        ])
        let decoded = try JSONDecoder().decode(
            SavedVaults.self,
            from: JSONEncoder().encode(saved)
        )
        #expect(decoded == saved)
        #expect(decoded.vaults.first?.showsInFinder == true)
        #expect(decoded.vaults.last?.showsInFinder == false)
    }

    @Test("setShowsInFinder reports whether anything changed, and finds either path spelling")
    func setting() {
        var saved = SavedVaults(vaults: [
            VaultLocation(imagePath: "/tmp/A.sparsebundle", volumeName: "A")
        ])
        // A `mutating` call cannot sit inside `#expect` — hoist each result first (docs/NOTES.md).
        let turnedOn = saved.setShowsInFinder(true, forPath: "/tmp/A.sparsebundle")
        #expect(turnedOn)
        #expect(saved.vaults.first?.showsInFinder == true)
        // Same value again: no change, so the caller can skip the write and the sidebar rebuild.
        let again = saved.setShowsInFinder(true, forPath: "/tmp/A.sparsebundle")
        #expect(!again)
        // The other spelling of the same path is the same vault — the identity rule `SavedVaults`
        // exists for, applied to this mutator too.
        let byResolvedPath = saved.setShowsInFinder(false, forPath: "/private/tmp/A.sparsebundle")
        #expect(byResolvedPath)
        #expect(saved.vaults.first?.showsInFinder == false)
        let absent = saved.setShowsInFinder(true, forPath: "/tmp/nothing.sparsebundle")
        #expect(!absent)
    }

    @Test("the volume name survives a visibility change")
    func settingKeepsTheName() {
        // Why this is a mutator rather than a read-modify-`add`: `add` replaces the whole entry, so a
        // caller rebuilding a `VaultLocation` to flip one flag would write back whatever name it had
        // to hand — clobbering the one the unlock path reads off the real mount.
        var saved = SavedVaults(vaults: [
            VaultLocation(imagePath: "/v/A.sparsebundle", volumeName: "Renamed Later")
        ])
        saved.setShowsInFinder(true, forPath: "/v/A.sparsebundle")
        #expect(saved.vaults.first?.volumeName == "Renamed Later")
    }
}
