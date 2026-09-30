import Foundation
import Testing

@testable import DirnexCore

/// Following a vault's image when the user renames or moves it in a pane (PLAN.md §M19).
///
/// The bug this closes is quiet in the expensive direction: the sidebar row keeps its old path and
/// looks perfectly normal, and the passphrase stays filed under a path nothing will ask about again.
/// So the assertions here are about *which* vault a record names and *where* it may have gone —
/// never about what the operation was called, which is the thing that cannot be trusted once undo
/// enters the picture.
@Suite("Vault image moves")
struct VaultImageMoveTests {
    private let vaults = SavedVaults(vaults: [
        VaultLocation(imagePath: "/vaults/Personal.sparsebundle", volumeName: "Personal"),
        VaultLocation(imagePath: "/elsewhere/Other.sparsebundle", volumeName: "Other")
    ])

    private func renameRecord(from old: String, to new: String) -> UndoRecord {
        .rename(from: .local(new), to: .local(old))
    }

    @Test("a renamed image names its vault, in both directions")
    func renameNamesTheVaultBothWays() {
        // `.rename(from:to:)` journals the *inverse* — restore the new path back to the old — so the
        // record's own spelling is already "backwards". Reading both ends is what makes that
        // irrelevant, and it is the same reason undo needs no special case.
        let record = renameRecord(
            from: "/vaults/Personal.sparsebundle",
            to: "/vaults/Work.sparsebundle"
        )
        let found = VaultImageMove.candidates(in: record, vaults: vaults)
        #expect(found.count == 1)
        #expect(found.first?.vault.volumeName == "Personal")
        #expect(found.first?.destination == "/vaults/Work.sparsebundle")
    }

    @Test("undo names the same vault, pointing back the way it came")
    func undoPointsBack() {
        // After the rename has been followed, the store holds the new path — and undoing moves the
        // file back. The same record must then produce the reverse candidate, with nothing
        // remembering which way time was running.
        let afterRename = SavedVaults(vaults: [
            VaultLocation(imagePath: "/vaults/Work.sparsebundle", volumeName: "Personal")
        ])
        let record = renameRecord(
            from: "/vaults/Personal.sparsebundle",
            to: "/vaults/Work.sparsebundle"
        )
        let found = VaultImageMove.candidates(in: record, vaults: afterRename)
        #expect(found.count == 1)
        #expect(found.first?.destination == "/vaults/Personal.sparsebundle")
    }

    @Test("a vault inside a moved folder is followed too")
    func aMovedFolderCarriesItsVault() {
        // The reported gesture was F2 on the image, but F6 on the folder above it breaks the row in
        // exactly the same way — and costs nothing extra, because containment is the same rebase
        // rule the rest of the vault machinery uses.
        let record = UndoRecord(
            label: .move,
            steps: [.restore(from: .local("/moved/vaults"), to: .local("/vaults"))]
        )
        let found = VaultImageMove.candidates(in: record, vaults: vaults)
        #expect(found.count == 1)
        #expect(found.first?.destination == "/moved/vaults/Personal.sparsebundle")
    }

    @Test("a sibling that merely shares a prefix is left alone")
    func prefixSiblingIsNotFollowed() {
        // The boundary a bare `hasPrefix` gets wrong — and here it would re-point a vault the user
        // never touched, which is worse than the bug being fixed.
        let record = UndoRecord(
            label: .move,
            steps: [.restore(from: .local("/moved/vaultsBackup"), to: .local("/vaultsBackup"))]
        )
        #expect(VaultImageMove.candidates(in: record, vaults: vaults).isEmpty)
    }

    @Test("a trashed vault keeps its path, so Put Back brings the row back to life")
    func trashIsNotFollowed() {
        // `moveToTrash` journals the identical `restore` step a move does, so this is a *decision*
        // rather than something the shape rules out: following it would leave the row pointing into
        // the Trash, where the vault would still unlock. Leaving the path alone is also what makes
        // Put Back repair the row on its own.
        let record = UndoRecord(
            label: .moveToTrash,
            steps: [.restore(
                from: .local("/Users/me/.Trash/Personal.sparsebundle"),
                to: .local("/vaults/Personal.sparsebundle")
            )]
        )
        #expect(VaultImageMove.candidates(in: record, vaults: vaults).isEmpty)
    }

    @Test("a copy names nothing — the original keeps its row and its passphrase")
    func copyIsNotFollowed() {
        let record = UndoRecord(
            label: .copy,
            steps: [.removeCopy(
                source: .local("/vaults/Personal.sparsebundle"),
                copy: .local("/backup/Personal.sparsebundle")
            )]
        )
        #expect(VaultImageMove.candidates(in: record, vaults: vaults).isEmpty)
    }

    @Test("a move onto a remote backend is not followed")
    func remoteDestinationsAreIgnored() {
        // A vault is a mounted local volume; an image path on an SFTP server cannot be attached, so
        // re-pointing the row there would replace a dead row with a nonsensical one.
        let record = UndoRecord(
            label: .move,
            steps: [.restore(
                from: VFSPath(
                    backend: .sftp(SFTPLocation(host: "host", username: "me")),
                    path: "/remote/Personal.sparsebundle"
                ),
                to: .local("/vaults/Personal.sparsebundle")
            )]
        )
        #expect(VaultImageMove.candidates(in: record, vaults: vaults).isEmpty)
    }

    @Test("a record naming no vault at all produces nothing")
    func unrelatedMovesAreIgnored() {
        let record = UndoRecord(
            label: .move,
            steps: [.restore(from: .local("/tmp/notes.txt"), to: .local("/tmp/old-notes.txt"))]
        )
        #expect(VaultImageMove.candidates(in: record, vaults: vaults).isEmpty)
    }

    @Test("following a move keeps the vault's place in the sidebar")
    func movePreservesOrder() {
        // A remove-then-add is the obvious implementation and it silently sends the row to the
        // bottom of the Vaults section — a reordering caused by renaming a file.
        var saved = vaults
        // Hoisted: a `mutating` call cannot sit inside `#expect` (docs/NOTES.md ▸ Testing).
        let moved = saved.move(
            imagePath: "/vaults/Personal.sparsebundle", to: "/vaults/Work.sparsebundle"
        )
        #expect(moved)
        #expect(saved.vaults.map(\.volumeName) == ["Personal", "Other"])
        #expect(saved.vaults[0].imagePath == "/vaults/Work.sparsebundle")
        // The volume name is untouched: what was renamed is the file, not the volume inside it.
        #expect(saved.vaults[0].volumeName == "Personal")
        let absent = saved.move(imagePath: "/nothing/here.sparsebundle", to: "/x")
        #expect(!absent)
    }
}
