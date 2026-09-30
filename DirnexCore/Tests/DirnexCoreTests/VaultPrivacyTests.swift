import Foundation
import Testing

@testable import DirnexCore

/// The rule that keeps a locked vault's file names out of everything Dirnex remembers implicitly
/// (PLAN.md §M19). The mount points here are the shapes `hdiutil` really answers with — `/Volumes/…`
/// for an attached image, and the `/private` spelling for the image path itself, which is what makes
/// the normalization on both sides load-bearing rather than decorative.
@Suite("Vault privacy")
struct VaultPrivacyTests {
    private func attached(
        image: String,
        mountPoint: String?,
        encrypted: Bool = true
    ) -> DiskImageMount.AttachedImage {
        DiskImageMount.AttachedImage(
            imagePath: image, isEncrypted: encrypted, mountPoint: mountPoint
        )
    }

    // MARK: - Which mount points count

    @Test("an attached saved vault contributes its mount point, a locked one contributes nothing")
    func mountPointsOfSavedVaults() {
        let vaults = SavedVaults(vaults: [
            VaultLocation(imagePath: "/tmp/open.sparsebundle", volumeName: "Open"),
            VaultLocation(imagePath: "/tmp/shut.sparsebundle", volumeName: "Shut")
        ])
        let points = VaultPrivacy.mountPoints(
            of: vaults,
            attached: [
                attached(image: "/private/tmp/open.sparsebundle", mountPoint: "/Volumes/Open")
            ]
        )
        #expect(points == ["/Volumes/Open"])
    }

    @Test("an encrypted image nobody saved still counts — Disk Utility can unlock one too")
    func mountPointsOfUnsavedEncryptedImage() {
        let points = VaultPrivacy.mountPoints(
            of: SavedVaults(),
            attached: [attached(image: "/tmp/stranger.dmg", mountPoint: "/Volumes/Stranger")]
        )
        #expect(points == ["/Volumes/Stranger"])
    }

    @Test("an unencrypted image is ordinary storage and contributes nothing")
    func plainImageIsNotAVault() {
        let points = VaultPrivacy.mountPoints(
            of: SavedVaults(),
            attached: [
                attached(image: "/tmp/plain.dmg", mountPoint: "/Volumes/Plain", encrypted: false)
            ]
        )
        #expect(points.isEmpty)
    }

    @Test("a vault listed twice — as itself and as an encrypted image — yields one mount point")
    func mountPointsAreDeduplicated() {
        let vaults = SavedVaults(vaults: [
            VaultLocation(imagePath: "/tmp/v.sparsebundle", volumeName: "V")
        ])
        let points = VaultPrivacy.mountPoints(
            of: vaults,
            attached: [attached(image: "/private/tmp/v.sparsebundle", mountPoint: "/Volumes/V")]
        )
        #expect(points == ["/Volumes/V"])
    }

    // MARK: - What is inside

    @Test("the mount point itself, and anything under it, is inside")
    func containmentIncludesTheRootAndDescendants() {
        let points = ["/Volumes/Vault"]
        #expect(VaultPrivacy.isInside("/Volumes/Vault", mountPoints: points))
        #expect(VaultPrivacy.isInside("/Volumes/Vault/taxes", mountPoints: points))
        #expect(VaultPrivacy.isInside("/Volumes/Vault/taxes/2026/return.pdf", mountPoints: points))
    }

    @Test("the boundary is a whole component, so a same-prefixed volume is not inside")
    func containmentStopsAtAComponentBoundary() {
        // A bare `hasPrefix` passes every other test in this suite and fails this one, which is the
        // whole reason it is written down: the symptom would be a real directory silently dropped
        // out of session restore, with nothing logged.
        let points = ["/Volumes/Vault"]
        #expect(!VaultPrivacy.isInside("/Volumes/VaultBackup", mountPoints: points))
        #expect(!VaultPrivacy.isInside("/Volumes/VaultBackup/taxes", mountPoints: points))
        #expect(!VaultPrivacy.isInside("/Volumes/Vau", mountPoints: points))
    }

    @Test("both sides are normalized, so the two spellings of one place agree")
    func containmentFoldsThePrivatePrefix() {
        #expect(VaultPrivacy.isInside("/private/tmp/mnt/secret", mountPoints: ["/tmp/mnt"]))
        #expect(VaultPrivacy.isInside("/tmp/mnt/secret", mountPoints: ["/private/tmp/mnt"]))
    }

    @Test("with no vault mounted nothing is inside")
    func nothingIsInsideWhenNothingIsMounted() {
        #expect(!VaultPrivacy.isInside("/Volumes/Vault/taxes", mountPoints: []))
    }

    @Test("a degenerate mount point is ignored rather than swallowing every path")
    func emptyOrRootMountPointIsIgnored() {
        // `hdiutil` should never answer either, and if it ever did, treating "/" as a vault would
        // quietly disable frecency and session restore for the whole machine.
        #expect(!VaultPrivacy.isInside("/Users/oleg/Documents", mountPoints: ["", "/"]))
    }

    @Test("a renamed volume carries the path inside it along")
    func rebaseFollowsTheRename() {
        #expect(
            VaultPrivacy.rebase("/Volumes/Personal", from: "/Volumes/Personal", to: "/Volumes/Work")
                == "/Volumes/Work"
        )
        #expect(VaultPrivacy.rebase(
            "/Volumes/Personal/taxes/2026", from: "/Volumes/Personal", to: "/Volumes/Work"
        ) == "/Volumes/Work/taxes/2026")
        // The destination is used exactly as `hdiutil` reported it, never rebuilt from the typed
        // name: a collision remounts at `/Volumes/Work 1` (probed), and the pane has to follow the
        // volume rather than the wish.
        #expect(VaultPrivacy.rebase(
            "/Volumes/Personal/taxes", from: "/Volumes/Personal", to: "/Volumes/Work 1"
        ) == "/Volumes/Work 1/taxes")
    }

    @Test("a rebase draws the same boundary the inside-ness test does")
    func rebaseAgreesWithIsInside() {
        // The whole reason it lives beside `isInside`: a sibling volume that merely shares a prefix
        // is not inside, and must not be dragged along by a rename either.
        #expect(VaultPrivacy.rebase(
            "/Volumes/PersonalBackup/x", from: "/Volumes/Personal", to: "/Volumes/Work"
        ) == nil)
        #expect(VaultPrivacy.rebase("/Users/oleg", from: "/Volumes/Personal", to: "/Volumes/Work")
            == nil)
        #expect(VaultPrivacy.rebase("/Users/oleg", from: "/", to: "/Volumes/Work") == nil)
        #expect(VaultPrivacy.rebase("/Users/oleg", from: "", to: "/Volumes/Work") == nil)
        // Both spellings of one place, as everywhere else in this type.
        #expect(VaultPrivacy.rebase("/private/tmp/mnt/x", from: "/tmp/mnt", to: "/Volumes/Work")
            == "/Volumes/Work/x")
    }

    @Test("only a local path can be inside a vault")
    func remoteBackendsAreNeverInside() {
        let points = ["/Volumes/Vault"]
        #expect(VaultPrivacy.isInside(VFSPath.local("/Volumes/Vault/x"), mountPoints: points))
        #expect(!VaultPrivacy.isInside(
            VFSPath(
                backend: .sftp(SFTPLocation(host: "host", username: "me")),
                path: "/Volumes/Vault/x"
            ),
            mountPoints: points
        ))
    }

    // MARK: - Forgetting

    @Test("locking forgets the vault's directories and leaves every other one alone")
    func frecencyForgetsOnlyWhatThePredicateClaims() {
        var frecency = Frecency()
        frecency.visit(.local("/Users/oleg/Documents"))
        frecency.visit(.local("/Volumes/Vault/taxes"))
        frecency.visit(.local("/Volumes/VaultBackup/notes"))

        let points = ["/Volumes/Vault"]
        let removed = frecency.forget { VaultPrivacy.isInside($0, mountPoints: points) }

        #expect(removed)
        let paths = frecency.entries.map(\.path.path).sorted()
        #expect(paths == ["/Users/oleg/Documents", "/Volumes/VaultBackup/notes"])
    }

    @Test("forgetting nothing reports nothing, so a lock with no history skips the write")
    func forgetReportsWhetherAnythingWent() {
        var frecency = Frecency()
        frecency.visit(.local("/Users/oleg/Documents"))
        let removed = frecency.forget { VaultPrivacy.isInside($0, mountPoints: ["/Volumes/Vault"]) }
        #expect(!removed)
        #expect(frecency.entries.count == 1)
    }
}
