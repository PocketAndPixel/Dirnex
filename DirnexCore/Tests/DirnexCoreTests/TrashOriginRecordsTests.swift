import Foundation
import Testing

@testable import DirnexCore

/// The put-back records Dirnex writes for its own deletes (PLAN.md §M26 Slice 4) — the store that
/// takes back the one regression M26 knowingly introduced, since the `renamex_np` that moves a
/// provider item cannot write Finder's `ptbL`/`ptbN` pair.
///
/// The claims worth pinning are the two the slice's controls name: a provider item that today has
/// no origin gets one, and an ordinary local item is **still** answered by Finder's record rather
/// than by ours — which is the narrowness half, and the one that keeps the merge rule from quietly
/// inverting.
@Suite("Trash origin records")
struct TrashOriginRecordsTests {
    private static let home = VFSPath.local("/Users/oleg")
    private static let mount = VFSPath.local("/Users/oleg/Library/CloudStorage/Box-Box")
    private static let providerTrash = mount.appending(".Trash")
    private static let homeTrash = home.appending(".Trash")

    private static func trashed(_ original: VFSPath, in trash: VFSPath) -> DeletePass.Restoration {
        DeletePass.Restoration(original: original, trashed: trash.appending(original.lastComponent))
    }

    private static func recorded(_ restorations: [DeletePass.Restoration]) -> TrashOriginRecords {
        var records = TrashOriginRecords()
        records.record(restorations, unless: { _ in false })
        return records
    }

    // MARK: - The fix

    @Test("an item with no Finder record is answered from what the delete knew")
    func recordsAnswerWhereFinderIsSilent() {
        let landed = Self.providerTrash.appending("notes.txt")
        let records = Self.recorded(
            [Self.trashed(Self.mount.appending("notes.txt"), in: Self.providerTrash)]
        )

        #expect(records.origin(of: landed, finderRecord: nil) == TrashOrigin(
            directory: Self.mount,
            name: "notes.txt"
        ))
    }

    /// Today's behaviour, and therefore what the fix has to *change*: with nothing stored, the same
    /// question has no answer and the restore flow says so by name.
    @Test("without a record there is still no answer, so the store is what changes it")
    func emptyStoreAnswersNothing() {
        let records = TrashOriginRecords()
        #expect(
            records.origin(of: Self.providerTrash.appending("notes.txt"), finderRecord: nil) == nil
        )
    }

    // MARK: - The merge rule

    /// The narrowness control. An ordinary local delete goes through `trashItem`, which writes the
    /// `.DS_Store` pair — so if ours could override it, a file Finder recorded one way and we
    /// another would restore to the wrong folder.
    @Test("Finder's record wins wherever it exists")
    func finderRecordWins() {
        let landed = Self.homeTrash.appending("report.pdf")
        let records = Self.recorded([
            DeletePass.Restoration(original: .local("/Users/oleg/Wrong/report.pdf"), trashed: landed)
        ])
        let finder = TrashOrigin(directory: .local("/Users/oleg/Documents"), name: "report.pdf")

        #expect(records.origin(of: landed, finderRecord: finder) == finder)
    }

    /// A landing path is the key, never the filename: the merged Trash spans `~/.Trash`, every
    /// volume's, iCloud's and every provider mount's at once, and two of them can hold the same name.
    @Test("two trashes holding the same name keep separate origins")
    func keyedOnTheLandingPathNotTheName() {
        let records = Self.recorded([
            Self.trashed(Self.mount.appending("a.txt"), in: Self.providerTrash),
            Self.trashed(.local("/Users/oleg/Desktop/a.txt"), in: Self.homeTrash)
        ])

        #expect(
            records.origin(of: Self.providerTrash.appending("a.txt"), finderRecord: nil)?.directory
                == Self.mount
        )
        #expect(
            records.origin(of: Self.homeTrash.appending("a.txt"), finderRecord: nil)?.directory
                == .local("/Users/oleg/Desktop")
        )
    }

    /// A trash renames a colliding newcomer (`a.txt 13-12-35-977.txt`), so the landing name and the
    /// origin name genuinely differ — restoring under the trash's name would rename the user's file.
    @Test("the name to restore under is the original's, not the landing's")
    func carriesTheOriginalName() {
        let landed = Self.providerTrash.appending("a.txt 13-12-35-977.txt")
        var records = TrashOriginRecords()
        records.record(
            [DeletePass.Restoration(original: Self.mount.appending("a.txt"), trashed: landed)],
            unless: { _ in false }
        )

        let origin = records.origin(of: landed, finderRecord: nil)
        #expect(origin?.name == "a.txt")
        #expect(origin?.destination == Self.mount.appending("a.txt"))
    }

    @Test("a landing path handed out again is answered by the newer delete")
    func newerRecordReplacesTheOlder() {
        let landed = Self.homeTrash.appending("a.txt")
        let records = Self.recorded([
            DeletePass.Restoration(original: .local("/Users/oleg/First/a.txt"), trashed: landed),
            DeletePass.Restoration(original: .local("/Users/oleg/Second/a.txt"), trashed: landed)
        ])

        #expect(records.records.count == 1)
        #expect(
            records.origin(of: landed, finderRecord: nil)?.directory == .local("/Users/oleg/Second")
        )
    }

    // MARK: - The vault rule

    /// PLAN.md §M19: a record pairs a file's name with the folder it came from and outlives both,
    /// which is exactly the implicit memory a vault's contents must stay out of.
    @Test("nothing from inside an unlocked vault is recorded")
    func vaultPathsAreNeverRecorded() {
        let vault = VFSPath.local("/Volumes/Vault")
        var records = TrashOriginRecords()
        let changed = records.record(
            [
                Self.trashed(vault.appending("taxes.pdf"), in: vault.appending(".Trashes/501")),
                Self.trashed(.local("/Users/oleg/Desktop/ok.txt"), in: Self.homeTrash)
            ],
            unless: { VaultPrivacy.isInside($0, mountPoints: [vault.path]) }
        )

        #expect(changed)
        #expect(records.records.map(\.origin.name) == ["ok.txt"])
    }

    /// Both ends, not just the origin: an item trashed *into* a vault's own trash names the file
    /// just as plainly as one taken out of it.
    @Test("a landing inside a vault is skipped too")
    func vaultLandingIsSkipped() {
        let vault = VFSPath.local("/Volumes/Vault")
        var records = TrashOriginRecords()
        records.record(
            [DeletePass.Restoration(
                original: .local("/Users/oleg/Desktop/a.txt"),
                trashed: vault.appending(".Trashes/501/a.txt")
            )],
            unless: { VaultPrivacy.isInside($0, mountPoints: [vault.path]) }
        )

        #expect(records.records.isEmpty)
    }

    /// The second wall, called when a vault locks — for the image unlocked outside Dirnex and
    /// browsed in the window before the mount notification landed.
    @Test("locking a vault forgets records naming it at either end")
    func forgetDropsBothEnds() {
        let vault = "/Volumes/Vault"
        var records = Self.recorded([
            Self.trashed(.local("/Volumes/Vault/taxes.pdf"), in: Self.homeTrash),
            DeletePass.Restoration(
                original: .local("/Users/oleg/Desktop/a.txt"),
                trashed: .local("/Volumes/Vault/.Trashes/501/a.txt")
            ),
            Self.trashed(.local("/Users/oleg/Desktop/keep.txt"), in: Self.homeTrash)
        ])

        let forgot = records.forget { VaultPrivacy.isInside($0, mountPoints: [vault]) }
        #expect(forgot)
        #expect(records.records.map(\.origin.name) == ["keep.txt"])
    }

    // MARK: - Staying bounded

    @Test("a record whose item has left the trash is pruned away")
    func prunesItemsThatAreGone() {
        var records = Self.recorded([
            Self.trashed(Self.mount.appending("gone.txt"), in: Self.providerTrash),
            Self.trashed(Self.mount.appending("here.txt"), in: Self.providerTrash)
        ])

        // Hoisted: a `mutating` call cannot sit inside `#expect` (docs/NOTES.md ▸ Testing).
        let pruned = records.prune(
            stillTrashed: [Self.providerTrash.appending("here.txt")],
            inTrashesRead: [Self.providerTrash]
        )
        #expect(pruned)
        #expect(records.records.map(\.origin.name) == ["here.txt"])
    }

    /// The half that keeps pruning from being data loss: a trash the pass could not list — an
    /// unmounted volume, a read that failed — contributes no entries at all, so "not in the listing"
    /// there means nothing.
    @Test("a trash the pass could not read keeps its records")
    func prunesOnlyWhatItActuallyRead() {
        var records = Self.recorded([
            Self.trashed(Self.mount.appending("a.txt"), in: Self.providerTrash),
            Self.trashed(.local("/Users/oleg/Desktop/b.txt"), in: Self.homeTrash)
        ])

        let prunedNothing = records.prune(stillTrashed: [], inTrashesRead: [])
        #expect(!prunedNothing)
        #expect(records.records.count == 2)

        let prunedHome = records.prune(stillTrashed: [], inTrashesRead: [Self.homeTrash])
        #expect(prunedHome)
        #expect(records.records.map(\.origin.name) == ["a.txt"])
    }

    /// Pruning runs when the Trash is *read*, so a user who never opens it never prunes. The cap is
    /// the backstop, and it drops the oldest — which is also the least likely to be put back.
    @Test("the store is capped, oldest first")
    func capDropsTheOldest() {
        var records = TrashOriginRecords(limit: 2)
        for index in 0..<4 {
            records.record(
                [Self.trashed(.local("/Users/oleg/Desktop/\(index).txt"), in: Self.homeTrash)],
                unless: { _ in false }
            )
        }

        #expect(records.records.map(\.origin.name) == ["2.txt", "3.txt"])
    }

    // MARK: - Persistence

    /// Put Back is the gesture for an item sitting in the Trash a week later, so the store is
    /// worthless if it does not survive relaunch.
    @Test("round-trips through JSON")
    func roundTripsThroughJSON() throws {
        let records = Self.recorded(
            [Self.trashed(Self.mount.appending("a.txt"), in: Self.providerTrash)]
        )
        let data = try JSONEncoder().encode(records)
        let decoded = try JSONDecoder().decode(TrashOriginRecords.self, from: data)

        #expect(decoded.records == records.records)
        #expect(
            decoded.origin(of: Self.providerTrash.appending("a.txt"), finderRecord: nil)?.directory
                == Self.mount
        )
    }
}
