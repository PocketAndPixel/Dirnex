import Foundation
import Testing

@testable import DirnexCore

/// The seam PLAN.md §M26 opens: `LocalBackend` keeps every decision about a Trash move and hands the
/// one byte-touching step to an injected ``TrashPerformer``, because the only spelling that works
/// for a File Provider item (`NSWorkspace.recycle`) lives in AppKit and this package is headless.
///
/// Driven against a fake for the same reason ``LocalBackendTrashRefusalTests`` is: what the app's
/// real performer does is a property of macOS, measured live rather than asserted here (the live
/// half is the M26 Slice 2 run — LaunchServices-launched, across all five provider domains). What
/// *is* ours is that the injection is honoured, that a `nil` landing is not a failure, and that
/// neither refusal the backend owns was moved into the performer along with the move.
@Suite("LocalBackend trash performer")
struct LocalBackendTrashPerformerTests {
    /// Records what it was asked to move and answers however the test told it to.
    private final class Fake: TrashPerformer, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [URL] = []
        private let answer: @Sendable (URL) throws -> URL?

        init(answer: @escaping @Sendable (URL) throws -> URL?) { self.answer = answer }

        var urls: [URL] { lock.withLock { asked } }

        func moveToTrash(_ url: URL) throws -> URL? {
            lock.withLock { asked.append(url) }
            return try answer(url)
        }
    }

    private static func landing(_ path: String) -> @Sendable (URL) throws -> URL? {
        { _ in URL(fileURLWithPath: path) }
    }

    // MARK: - The injection is honoured

    /// The whole point of the seam: the backend must ask whoever was injected, and report back the
    /// landing path that performer named. Without the second half a `DeletePass.Restoration` has
    /// nowhere to put the item back to, so ⌘Z after an F8 would silently do nothing.
    @Test("the injected performer is asked, and its landing path is what comes back")
    func routesThroughThePerformer() throws {
        let fake = Fake(answer: Self.landing("/Users/someone/.Trash/report.pdf"))
        let backend = LocalBackend(trashPerformer: fake)

        let landed = try backend.trashItem(at: .local("/tmp/dnx/report.pdf"))

        #expect(fake.urls.map(\.path) == ["/tmp/dnx/report.pdf"])
        #expect(landed == .local("/Users/someone/.Trash/report.pdf"))
    }

    /// A performer that cannot say where the item went is not a performer that failed — the file is
    /// gone either way, and the caller loses an undo record rather than correctness. Pinned because
    /// the tempting reading of a `nil` is "nothing happened", which would turn a successful delete
    /// into a reported failure.
    @Test("a performer that cannot name the landing place still succeeds")
    func nilLandingIsNotAFailure() throws {
        let backend = LocalBackend(trashPerformer: Fake(answer: { _ in nil }))

        #expect(try backend.trashItem(at: .local("/tmp/dnx/report.pdf")) == nil)
    }

    // MARK: - The decisions stay in the backend

    /// The narrowness control PLAN.md §M26 names: a Trash-less volume's refusal has to keep reaching
    /// ``TrashRefusal/isVolumeWithoutTrash`` through the new route, or M25's confirmed permanent
    /// delete stops being offered on an SMB share and F8 there reports an error instead.
    @Test("a Trash-less volume's refusal survives the seam")
    func featureUnsupportedStillBecomesTheNamedRefusal() {
        let backend = LocalBackend(trashPerformer: Fake(answer: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }))

        var thrown: (any Error)?
        #expect(throws: (any Error).self) {
            do { try backend.trashItem(at: .local("/Volumes/Share/t.txt")) } catch {
                thrown = error
                throw error
            }
        }
        #expect(thrown.map { TrashRefusal.isVolumeWithoutTrash($0) } == true)
        #expect(thrown as? VFSError == .unsupported(.trash))
    }

    /// Everything else the performer throws is still translated by the backend rather than passed
    /// on raw — the mapping is a decision, and decisions do not move into an injected dependency.
    @Test("an ordinary refusal is still translated to the VFS vocabulary")
    func otherFailuresAreStillMapped() {
        let path = VFSPath.local("/tmp/dnx/report.pdf")
        let backend = LocalBackend(trashPerformer: Fake(answer: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }))

        var thrown: (any Error)?
        #expect(throws: (any Error).self) {
            do { try backend.trashItem(at: path) } catch {
                thrown = error
                throw error
            }
        }
        #expect(thrown as? VFSError == .permissionDenied(path))
    }

    /// The already-in-a-trash guard runs *before* anything is asked to move bytes. Asserting the
    /// performer was never called is the half that matters: a guard that threw after the move would
    /// pass a test reading only the error, having already emptied somebody's Trash item into itself.
    @Test("an item already in a trash is refused without asking the performer")
    func alreadyInTrashNeverReachesThePerformer() {
        let fake = Fake(answer: Self.landing("/never"))
        let backend = LocalBackend(trashPerformer: fake)
        let trashed = VFSPath.local(NSHomeDirectory() + "/.Trash/report.pdf")

        #expect(throws: (any Error).self) { try backend.trashItem(at: trashed) }
        #expect(fake.urls.isEmpty)
    }
}
