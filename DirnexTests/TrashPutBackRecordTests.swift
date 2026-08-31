import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app half of Put Back for a delete macOS wrote no record for (PLAN.md §M26 Slice 4): the
/// durable store, and the one place it meets Finder's `.DS_Store`.
///
/// The core value's rules — the merge direction, the vault skip, the key, the cap — are pinned in
/// `TrashOriginRecordsTests`. What can only be checked here is that the app **asks**: a store that
/// quietly stopped consulting its records, or an index that stopped consulting the store, would
/// leave every core test green while the feature did nothing (docs/NOTES.md ▸ the opt-in seam whose
/// default is "do it the old way").
/// `.serialized` on the merits, not as a flake workaround: the two write-side tests below swap
/// ``TrashOriginStore/shared``, which is one piece of process state two tests cannot hold at once.
/// Run in parallel they file into each other's scratch stores — measured while running a control,
/// where the collision showed up as *two* extra failures in tests that had nothing to do with it.
@MainActor
@Suite("Trash put-back records", .serialized)
struct TrashPutBackRecordTests {
    /// A scratch defaults domain, so a test never reads or writes the real store — which on the
    /// developer's own Mac holds their actual deletes.
    private static func store(
        isInVault: @escaping @MainActor (VFSPath) -> Bool = { _ in false }
    ) throws -> TrashOriginStore {
        let suite = try #require(
            UserDefaults(suiteName: "com.dirnex.tests.putback.\(UUID().uuidString)")
        )
        return TrashOriginStore(defaults: suite, isInVault: isInVault)
    }

    private static func trashed(_ original: VFSPath, in trash: VFSPath) -> DeletePass.Restoration {
        DeletePass.Restoration(original: original, trashed: trash.appending(original.lastComponent))
    }

    // MARK: - The store

    @Test("a recorded delete answers where the item came from")
    func recordThenRead() throws {
        let store = try Self.store()
        let mount = VFSPath.local("/Users/x/Library/CloudStorage/Box-Box")
        let trash = mount.appending(".Trash")
        store.record([Self.trashed(mount.appending("a.txt"), in: trash)])

        #expect(store.origin(of: trash.appending("a.txt"), finderRecord: nil) == TrashOrigin(
            directory: mount,
            name: "a.txt"
        ))
    }

    /// Put Back is the gesture for an item still in the Trash a week later, so a store that only
    /// lived as long as the process would be worth nothing.
    @Test("records survive a relaunch")
    func recordsPersist() throws {
        let suite = try #require(
            UserDefaults(suiteName: "com.dirnex.tests.putback.\(UUID().uuidString)")
        )
        let trash = VFSPath.local("/Users/x/.Trash")
        TrashOriginStore(defaults: suite, isInVault: { _ in false })
            .record([Self.trashed(.local("/Users/x/Desktop/a.txt"), in: trash)])

        let reopened = TrashOriginStore(defaults: suite, isInVault: { _ in false })
        #expect(reopened.origin(of: trash.appending("a.txt"), finderRecord: nil)?.directory
            == .local("/Users/x/Desktop"))
    }

    /// The vault rule, driven through the app's own guard rather than through the core's predicate —
    /// on a Mac with no vault attached ``VaultMounts`` answers `false` to everything, so a store that
    /// had stopped asking would look identical without this seam (PLAN.md §M19).
    @Test("nothing deleted out of an unlocked vault is written down")
    func vaultPathsAreNeverStored() throws {
        let vault = VFSPath.local("/Volumes/Vault")
        let store = try Self.store(
            isInVault: { VaultPrivacy.isInside($0, mountPoints: [vault.path]) }
        )
        let trash = VFSPath.local("/Users/x/.Trash")
        store.record([
            Self.trashed(vault.appending("taxes.pdf"), in: trash),
            Self.trashed(.local("/Users/x/Desktop/ok.txt"), in: trash)
        ])

        #expect(store.origin(of: trash.appending("taxes.pdf"), finderRecord: nil) == nil)
        #expect(store.origin(of: trash.appending("ok.txt"), finderRecord: nil) != nil)
    }

    /// Locking a vault takes the records with it, for the image unlocked outside Dirnex and browsed
    /// before the mount notification landed — the second wall `FrecencyStore` already has.
    @Test("locking a vault forgets what was recorded before Dirnex knew")
    func lockingForgets() throws {
        let store = try Self.store()
        let trash = VFSPath.local("/Users/x/.Trash")
        store.record([
            Self.trashed(.local("/Volumes/Vault/taxes.pdf"), in: trash),
            Self.trashed(.local("/Users/x/Desktop/keep.txt"), in: trash)
        ])

        store.forget(pathsUnder: "/Volumes/Vault")

        #expect(store.origin(of: trash.appending("taxes.pdf"), finderRecord: nil) == nil)
        #expect(store.origin(of: trash.appending("keep.txt"), finderRecord: nil) != nil)
    }

    @Test("emptying the Trash takes the records with it")
    func pruneDropsWhatIsGone() throws {
        let store = try Self.store()
        let trash = VFSPath.local("/Users/x/.Trash")
        store.record([Self.trashed(.local("/Users/x/Desktop/a.txt"), in: trash)])

        store.prune(stillTrashed: [], inTrashesRead: [trash])

        #expect(store.origin(of: trash.appending("a.txt"), finderRecord: nil) == nil)
    }

    /// The narrowness half of pruning: a trash whose listing failed contributes no entries, so
    /// "absent from the merged set" says nothing about it.
    @Test("a trash the gather could not read keeps its records")
    func pruneIsScopedToWhatWasRead() throws {
        let store = try Self.store()
        let trash = VFSPath.local("/Volumes/Photos/.Trashes/501")
        store.record([Self.trashed(.local("/Volumes/Photos/a.txt"), in: trash)])

        store.prune(stillTrashed: [], inTrashesRead: [.local("/Users/x/.Trash")])

        #expect(store.origin(of: trash.appending("a.txt"), finderRecord: nil) != nil)
    }

    // MARK: - The merge, where the restore flow actually reads it

    /// The wiring, end to end through the index Put Back uses. A provider trash keeps no
    /// `.DS_Store`, which a temp directory reproduces exactly — so this is the reported case: the
    /// item has no Finder record, and only the store can say where it came from.
    @Test("the restore index answers from the store where there is no .DS_Store")
    func indexConsultsTheStore() throws {
        let trash = try Self.temporaryTrash()
        defer { try? FileManager.default.removeItem(atPath: trash.path) }
        let landed = trash.appending("a.txt")
        var recorded = TrashOriginRecords()
        recorded.record(
            [DeletePass.Restoration(original: .local("/Users/x/Desktop/a.txt"), trashed: landed)],
            unless: { _ in false }
        )

        var index = TrashOriginIndex(backend: LocalBackend(), recorded: recorded)
        #expect(index.origin(of: landed)?.destination == .local("/Users/x/Desktop/a.txt"))
    }

    /// Today's behaviour, which the fix has to be what changes: with nothing recorded the same item
    /// has no origin, and Put Back says so by name rather than guessing at a folder.
    @Test("with nothing recorded the same item still has no known origin")
    func indexStillAnswersNothingWithoutARecord() throws {
        let trash = try Self.temporaryTrash()
        defer { try? FileManager.default.removeItem(atPath: trash.path) }

        var index = TrashOriginIndex(backend: LocalBackend(), recorded: TrashOriginRecords())
        #expect(index.origin(of: trash.appending("a.txt")) == nil)
    }

    // MARK: - The write side

    /// The half no other test here can see: that a delete actually **files** its origin. Driven
    /// through the shipped `runDelete`, because a store nobody writes to answers nothing however
    /// well its own rules are pinned.
    @Test("an F8 delete files where the item came from")
    func deleteRecordsTheOrigin() async throws {
        // The pane first: building one installs the harness's own scratch store, which would
        // otherwise overwrite the one this test is watching.
        let window = TrashlessProbe.window()
        let pane = TrashlessProbe.pane(with: RefusingBackend(refusal: .trashesNormally), in: window)
        let entry = TrashlessProbe.file("t.txt")

        let store = try Self.store()
        let previous = TrashOriginStore.shared
        TrashOriginStore.shared = store
        defer { TrashOriginStore.shared = previous }

        pane.runDelete([entry.path], permanent: false)

        let landed = VFSPath.local("/.Trash/t.txt")
        await settle { store.origin(of: landed, finderRecord: nil) != nil }
        #expect(store.origin(of: landed, finderRecord: nil) == TrashOrigin(
            directory: TrashlessProbe.directory,
            name: "t.txt"
        ))
    }

    /// The narrowness half: a **permanent** delete is irreversible and produces no restoration, so
    /// it must leave nothing behind to put back either.
    @Test("a permanent delete files nothing")
    func permanentDeleteRecordsNothing() async throws {
        let window = TrashlessProbe.window()
        let backend = RefusingBackend(refusal: .trashesNormally)
        let pane = TrashlessProbe.pane(with: backend, in: window)

        let store = try Self.store()
        let previous = TrashOriginStore.shared
        TrashOriginStore.shared = store
        defer { TrashOriginStore.shared = previous }

        pane.runDelete([TrashlessProbe.file("t.txt").path], permanent: true)

        await settle { !backend.removedPaths.isEmpty }
        #expect(store.origin(of: .local("/.Trash/t.txt"), finderRecord: nil) == nil)
    }

    private static func temporaryTrash() throws -> VFSPath {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-putback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .local(url.path)
    }
}
