import Foundation
import Testing

@testable import DirnexCore

/// The one delete loop three flows share (F8, the F6 move into an archive, a directory sync's
/// deletes), and specifically the three outcomes a `try?` cannot tell apart — which is what two of
/// those flows were using until 2026-08-25.
@Suite("Delete pass")
struct DeletePassTests {
    private static func path(_ name: String) -> VFSPath { .local("/Volumes/Photos/\(name)") }

    // MARK: - The three outcomes

    @Test("a trashed item reports where it landed, so undo can restore it")
    func trashedItemsAreJournaled() {
        let backend = DeletePassBackend()
        let outcome = DeletePass.run(
            [Self.path("a.txt"), Self.path("b.txt")],
            using: backend,
            permanent: false
        )

        #expect(outcome.failures.isEmpty)
        #expect(outcome.refused.isEmpty)
        #expect(outcome.restorations == [
            DeletePass.Restoration(original: Self.path("a.txt"), trashed: .local("/.Trash/a.txt")),
            DeletePass.Restoration(original: Self.path("b.txt"), trashed: .local("/.Trash/b.txt"))
        ])
    }

    /// The reported bug's own case. A volume with no Trash leaves the item exactly where it was, so
    /// it must come back as something the caller can *ask* about — not as a failure, and above all
    /// not as nothing, which is what `try?` made of it.
    @Test("a volume with no Trash is refused, not failed — and the item is untouched")
    func trashlessVolumeIsRefused() {
        let backend = DeletePassBackend(trash: .noTrashOnVolume)
        let outcome = DeletePass.run([Self.path("a.txt")], using: backend, permanent: false)

        #expect(outcome.refused == [Self.path("a.txt")])
        #expect(outcome.failures.isEmpty)
        #expect(outcome.restorations.isEmpty)
        #expect(backend.removed.isEmpty)
    }

    /// The narrowness control that keeps "refused" from becoming "anything that went wrong". A
    /// permission failure is a real failure: a caller answering it with "shall I delete this for
    /// good instead?" would be offering to do harm in response to something breaking.
    @Test("a real failure stays a failure")
    func realFailureIsReported() {
        let backend = DeletePassBackend(trash: .permissionDenied)
        let outcome = DeletePass.run([Self.path("a.txt")], using: backend, permanent: false)

        #expect(outcome.refused.isEmpty)
        #expect(outcome.restorations.isEmpty)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.error == .permissionDenied(Self.path("a.txt")))
    }

    // MARK: - The batch

    /// What the `try?` version could not do at all: one bad item must not cost the others. This is
    /// what lets a sync of a hundred files report the three it could not remove.
    @Test("one item's outcome does not abandon the rest of the batch")
    func abatchIsFullyProcessed() {
        let backend = DeletePassBackend(trash: .mixed)
        let paths = [Self.path("ok.txt"), Self.path("denied.txt"), Self.path("notrash.txt")]

        let outcome = DeletePass.run(paths, using: backend, permanent: false)

        #expect(backend.trashAttempts == 3)
        #expect(outcome.restorations.map(\.original) == [Self.path("ok.txt")])
        #expect(outcome.failures.map(\.path) == [Self.path("denied.txt")])
        #expect(outcome.refused == [Self.path("notrash.txt")])
    }

    @Test("nothing to delete does nothing at all")
    func emptyBatchIsInert() {
        let backend = DeletePassBackend()
        let outcome = DeletePass.run([], using: backend, permanent: false)

        #expect(outcome == DeletePass.Outcome())
        #expect(backend.trashAttempts == 0)
        #expect(backend.removed.isEmpty)
    }

    // MARK: - Permanent

    /// The property the offer's termination rests on: a permanent pass consults no Trash, so it
    /// cannot produce a refusal for the caller to re-offer. Asserted rather than reasoned about,
    /// because a backend that answered otherwise would loop the sheet forever.
    @Test("a permanent pass deletes, journals nothing, and can refuse nothing")
    func permanentPassNeverRefuses() {
        let backend = DeletePassBackend(trash: .noTrashOnVolume)
        let outcome = DeletePass.run(
            [Self.path("a.txt"), Self.path("b.txt")],
            using: backend,
            permanent: true
        )

        #expect(backend.removed == [Self.path("a.txt"), Self.path("b.txt")])
        #expect(backend.trashAttempts == 0)
        #expect(outcome.refused.isEmpty)
        #expect(outcome.restorations.isEmpty)
        #expect(outcome.failures.isEmpty)
    }

    @Test("a failed permanent delete is reported")
    func permanentFailureIsReported() {
        let backend = DeletePassBackend(remove: .permissionDenied)
        let outcome = DeletePass.run([Self.path("a.txt")], using: backend, permanent: true)

        #expect(outcome.failures.map(\.path) == [Self.path("a.txt")])
        #expect(outcome.refused.isEmpty)
    }

    // MARK: - Classification

    @Test("the named volume refusal is recognised, and nothing else is")
    func refusalPredicateIsNarrow() {
        let path = Self.path("t.txt")
        #expect(TrashRefusal.isVolumeWithoutTrash(VFSError.unsupported(.trash)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.permissionDenied(path)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.notFound(path)))
        // The errno spelling the shared Cocoa mapper used to produce for 3328: recognising it would
        // undo the whole point of naming the case (`LocalBackend.trashFailure`).
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.io(path: path, code: 3328)))
        #expect(!TrashRefusal.isVolumeWithoutTrash(CancellationError()))
        // The neighbouring `.unsupported` reasons, and the one that matters most: an item already
        // in a trash is refused by `LocalBackend` itself, and re-offering *that* as a permanent
        // delete would answer a question nobody asked.
        #expect(!TrashRefusal.isVolumeWithoutTrash(
            VFSError.unsupported(.alreadyInTrash(name: "t.txt"))
        ))
        #expect(!TrashRefusal.isVolumeWithoutTrash(VFSError.unsupported(.removeItem)))
    }

    /// An error raised outside the `VFSError` vocabulary is still an item the caller must hear
    /// about — the silence this type exists to end is not allowed back in through the `catch`-all.
    @Test("an unrecognised error is still reported")
    func unknownErrorIsReported() {
        let backend = DeletePassBackend(trash: .foreign)
        let outcome = DeletePass.run([Self.path("a.txt")], using: backend, permanent: false)

        #expect(outcome.failures.map(\.path) == [Self.path("a.txt")])
        #expect(outcome.refused.isEmpty)
        #expect(outcome.restorations.isEmpty)
    }
}

/// A backend whose delete verbs can be told how to fail. A fake rather than a real volume because
/// the Trash-less refusal cannot be arranged on this Mac: every filesystem `hdiutil` can make
/// trashes fine (measured 2026-08-25 on ExFAT and HFS+), so it needs a network share. The syscall
/// that raises it is pinned separately in `LocalBackendTrashRefusalTests`.
private final class DeletePassBackend: VFSBackend, @unchecked Sendable {
    enum Behavior {
        case succeed
        case noTrashOnVolume
        case permissionDenied
        /// Something outside the `VFSError` vocabulary entirely.
        case foreign
        /// One of each, keyed on the file's name, to drive a mixed batch.
        case mixed
    }

    struct ForeignError: Error {}

    let id = VFSBackendID.local
    let capabilities: VFSCapabilities = [.read, .write, .trash]

    private let trashBehavior: Behavior
    private let removeBehavior: Behavior
    private let lock = NSLock()
    private var removedPaths: [VFSPath] = []
    private var trashCalls = 0

    init(trash: Behavior = .succeed, remove: Behavior = .succeed) {
        trashBehavior = trash
        removeBehavior = remove
    }

    var removed: [VFSPath] { lock.withLock { removedPaths } }
    var trashAttempts: Int { lock.withLock { trashCalls } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry { throw VFSError.notFound(path) }

    func trashItem(at path: VFSPath) throws -> VFSPath? {
        lock.withLock { trashCalls += 1 }
        try raise(resolve(trashBehavior, for: path), at: path)
        return .local("/.Trash/\(path.lastComponent)")
    }

    func removeItem(at path: VFSPath) throws {
        try raise(resolve(removeBehavior, for: path), at: path)
        lock.withLock { removedPaths.append(path) }
    }

    private func resolve(_ behavior: Behavior, for path: VFSPath) -> Behavior {
        guard behavior == .mixed else { return behavior }
        switch path.lastComponent {
        case "denied.txt": return .permissionDenied
        case "notrash.txt": return .noTrashOnVolume
        default: return .succeed
        }
    }

    private func raise(_ behavior: Behavior, at path: VFSPath) throws {
        switch behavior {
        case .succeed, .mixed: return
        case .noTrashOnVolume: throw VFSError.unsupported(.trash)
        case .permissionDenied: throw VFSError.permissionDenied(path)
        case .foreign: throw ForeignError()
        }
    }
}
