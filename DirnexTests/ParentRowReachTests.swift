import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The three connected-account backends, at file scope so the parameterized `arguments:` can read
/// them: the suite is `@MainActor`, and a static on it is main-actor-isolated where the argument
/// list is evaluated.
private enum RemoteFixture {
    static let sftp = VFSBackendID.sftp(
        SFTPLocation(host: "example.com", port: 2222, username: "oleg")
    )
    static let ftp = VFSBackendID.ftp(
        FTPLocation(host: "example.com", username: "oleg")
    )
    static let s3 = VFSBackendID.s3(
        S3Location(
            host: "127.0.0.1",
            port: 9599,
            bucket: "probe",
            region: "us-east-1",
            accessKeyID: "AKIAPROBEKEYEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    )

    static let all = [sftp, ftp, s3]
}

/// Which panes can walk up, and therefore draw a `..` row (PLAN.md §M1, widened §M21).
///
/// The rule had three spellings — `parentRowCount`, `goToParent()` and the Go menu's validator — and
/// all three read `backend == .local`. So every **remote** pane had no `..` row, a dead Backspace and
/// a grayed Go Up: SFTP since M5, FTP since M13, S3 since M21. Nothing caught it because each surface
/// is correct on its own terms and the listing looks perfectly ordinary; it was found by connecting
/// and standing inside an empty folder, where there is no row at all and the crumb is the only way
/// out (verified live 2026-08-13 against a local S3 endpoint).
///
/// The narrowness is pinned alongside the fix, because widening the predicate too far is the way this
/// goes wrong in the other direction: a search snapshot's synthetic parent is not a browsable
/// directory, and a `..` row there would offer a walk into nothing.
///
/// The panes are headless — the view is never loaded, and `canGoToParent` reads only the model.
@Suite("The `..` row's reach")
@MainActor
struct ParentRowReachTests {
    private static func pane(at path: VFSPath) -> PanelViewController {
        PanelViewController(
            backend: LocalBackend(),
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
    }

    // MARK: - The three remote backends

    @Test("a folder on a connected account walks up", arguments: RemoteFixture.all)
    func remoteFolderWalksUp(backend: VFSBackendID) {
        let pane = Self.pane(at: VFSPath(backend: backend, path: "/docs/api"))

        #expect(pane.canGoToParent)
        #expect(pane.parentRowCount == 1)
    }

    @Test("a connected account's own root does not", arguments: RemoteFixture.all)
    func remoteRootDoesNot(backend: VFSBackendID) {
        let pane = Self.pane(at: VFSPath(backend: backend, path: "/"))

        #expect(!pane.canGoToParent)
        #expect(pane.parentRowCount == 0)
    }

    /// The `..` row shifts every row⇄entry mapping by one, and a remote pane had never had that
    /// offset before. Asserted here rather than trusted: `parentRowCount` *is* the offset, so a pane
    /// that grows the row without the mapping following would point every command one row off.
    @Test("the row offset follows the row into a remote pane")
    func rowMappingShifts() {
        let pane = Self.pane(at: VFSPath(backend: RemoteFixture.s3, path: "/docs"))

        #expect(pane.isParentRow(0))
        #expect(pane.entryIndex(forRow: 0) == nil)
        #expect(pane.row(forEntryIndex: 0) == 1)
    }

    // MARK: - What must not change

    @Test("a local folder is unaffected")
    func localFolder() {
        let pane = Self.pane(at: .local("/Users/tester/Documents"))

        #expect(pane.canGoToParent)
        #expect(pane.parentRowCount == 1)
    }

    @Test("the local root is still the top")
    func localRoot() {
        let pane = Self.pane(at: .local("/"))

        #expect(!pane.canGoToParent)
        #expect(pane.parentRowCount == 0)
    }

    /// A results listing has a path that *looks* like a directory with a parent, which is exactly why
    /// the predicate cannot be "does `parentPath` exist": the parent of a search snapshot is not
    /// somewhere to go.
    @Test("a virtual results pane still shows no `..`")
    func virtualResults() {
        let pane = Self.pane(at: VFSPath(backend: .search, path: "/Results"))

        #expect(!pane.canGoToParent)
        #expect(pane.parentRowCount == 0)
    }

    @Test("an archive walks up at every level, its root included — that is the exit to the folder")
    func archive() {
        let backend = VFSBackendID.archive(forArchiveAt: "/Users/tester/pkg.zip")

        #expect(Self.pane(at: VFSPath(backend: backend, path: "/")).canGoToParent)
        #expect(Self.pane(at: VFSPath(backend: backend, path: "/inner")).parentRowCount == 1)
    }
}
