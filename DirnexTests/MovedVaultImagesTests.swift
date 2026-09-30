import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Correcting `hdiutil`'s answer for an image that was renamed while it was attached (PLAN.md §M19).
///
/// Measured on macOS 26 and the reason the type exists: renaming a mounted `.sparsebundle` succeeds,
/// the volume stays mounted, and `hdiutil info` goes on reporting the image under its *old* path
/// until it is detached — with nothing else in the plist to match on. Without this correction a vault
/// the user can plainly see mounted would draw a shut padlock and offer no Lock.
@Suite("Moved vault images", .serialized)
struct MovedVaultImagesTests {
    private func image(_ path: String, mountedAt mountPoint: String?) -> DiskImageMount.AttachedImage {
        DiskImageMount.AttachedImage(imagePath: path, isEncrypted: true, mountPoint: mountPoint)
    }

    /// A path that certainly does not exist — the state a renamed-while-attached image leaves
    /// behind, and the condition an alias is honored under.
    private func absentPath(_ leaf: String) -> String {
        "/tmp/dirnex-moved-vault-tests-\(UUID().uuidString)/\(leaf)"
    }

    @Test("an alias re-points the image hdiutil is still reporting under its old path")
    func aliasRewritesAStalePath() {
        MovedVaultImages.shared.forgetAll()
        let old = absentPath("Personal.sparsebundle")
        let new = absentPath("Work.sparsebundle")
        MovedVaultImages.shared.note(movedFrom: old, to: new)

        let resolved = MovedVaultImages.shared.resolving(
            [image(old, mountedAt: "/Volumes/Personal")]
        )
        #expect(resolved.first?.imagePath == new)
        // The mount point is what every caller actually wants out of this, and it is untouched.
        #expect(resolved.first?.mountPoint == "/Volumes/Personal")
        // And the question the sidebar asks now answers correctly for the vault's *new* path.
        #expect(DiskImageMount.isMounted(imageAtPath: new, in: resolved) == "/Volumes/Personal")
    }

    @Test("an alias is ignored once something occupies the reported path again")
    func aliasIsIgnoredWhenTheReportedPathExists() throws {
        MovedVaultImages.shared.forgetAll()
        // The whole safety story: honoring an alias only while `hdiutil`'s path is *missing* is what
        // removes any need to expire one. If a real image ever sits at that path again, it must be
        // reported as itself and never as the vault that used to live there.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-moved-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let occupied = directory.appendingPathComponent("Personal.sparsebundle").path
        try Data("not really an image".utf8).write(to: URL(fileURLWithPath: occupied))

        MovedVaultImages.shared.note(movedFrom: occupied, to: absentPath("Work.sparsebundle"))
        let resolved = MovedVaultImages.shared.resolving([image(occupied, mountedAt: "/Volumes/X")])
        #expect(resolved.first?.imagePath == occupied)
    }

    @Test("a second rename re-points the same alias rather than adding an unreachable one")
    func aliasesChain() {
        MovedVaultImages.shared.forgetAll()
        let first = absentPath("A.sparsebundle")
        let second = absentPath("B.sparsebundle")
        let third = absentPath("C.sparsebundle")
        MovedVaultImages.shared.note(movedFrom: first, to: second)
        MovedVaultImages.shared.note(movedFrom: second, to: third)

        // `hdiutil` is still saying `first` — it has never heard of `second` — so that is the key
        // that has to lead to `third`. A naively appended `second → third` pair would be keyed on a
        // path nothing ever reports, leaving the vault stranded after its second rename.
        let resolved = MovedVaultImages.shared.resolving([image(first, mountedAt: "/Volumes/A")])
        #expect(resolved.first?.imagePath == third)
    }

    @Test("both spellings of one path agree, and an unknown image is untouched")
    func normalizationAndPassthrough() {
        MovedVaultImages.shared.forgetAll()
        let stamp = UUID().uuidString
        MovedVaultImages.shared.note(
            movedFrom: "/private/tmp/dirnex-\(stamp)/A.sparsebundle",
            to: "/tmp/dirnex-\(stamp)/B.sparsebundle"
        )
        // `hdiutil` answers with the `/private` spelling while the user says `/tmp`; the alias has to
        // survive that, exactly as every other vault path comparison does.
        let resolved = MovedVaultImages.shared.resolving([
            image("/tmp/dirnex-\(stamp)/A.sparsebundle", mountedAt: "/Volumes/A"),
            image("/tmp/dirnex-\(stamp)/Unrelated.sparsebundle", mountedAt: "/Volumes/U")
        ])
        #expect(resolved[0].imagePath == "/tmp/dirnex-\(stamp)/B.sparsebundle")
        #expect(resolved[1].imagePath == "/tmp/dirnex-\(stamp)/Unrelated.sparsebundle")
        MovedVaultImages.shared.forgetAll()
    }
}
