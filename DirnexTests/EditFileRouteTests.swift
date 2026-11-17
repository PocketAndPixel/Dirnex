import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⇧F4 on a file that lives on a server (reported 2026-08-22).
///
/// F4 has routed by the row's own backend since M21 Slice 10 — that is what `editRoute(for:)` is —
/// and ⇧F4 had a second spelling that knew only about this Mac: whatever its dialog resolved went
/// straight to `openInEditor`, whose `localURL` is `file://` plus the path *inside* the backend. So
/// ⇧F4 on an S3 object asked macOS to open `/test2.txt`, Finder answered that the file couldn't be
/// found, and nothing was ever downloaded — while F4 on the very same row opened it perfectly.
///
/// Both halves are pinned, because they are two call sites and only the first was in the report: the
/// name that is already there, and the name ⇧F4 creates. The second is the one that reads as working
/// — the object really does appear on the server — right up until the editor is asked for.
///
/// **The pane is headless and has no `PanelHost`**, so the remote route stops at a fetch it cannot
/// start. That is what makes this flow safe to drive from a test at all, and it is also the
/// discriminator: `openInEditor` puts "Opening …" on the status line before it launches anything, so
/// a run that reached it is visible without an editor ever having opened.
///
/// The observable is `transientStatusToken` and **not the message itself**, which is a difference
/// the negative control had to teach: a transient message clears itself after four seconds, and the
/// reverted build's doomed `NSWorkspace` launch takes about sixty to fail — so the expiry wins the
/// race and the status line reads `nil` again by the time anything asks. The token only ever counts
/// up. Measured on the control: `token=1` in both tests, `status=nil` in one of them.
///
/// The backend has to record what it was *asked* for as well, or "took the remote route" and "did
/// nothing whatsoever" read the same (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("⇧F4's route")
struct EditFileRouteTests {
    /// The bucket root the dialog would be creating into. `Fixture` is `RemoteFetchFixtures`' —
    /// shared rather than re-declared so this suite's idea of "a file on a server" is the same one
    /// the fetch tests use.
    private static let directory = VFSPath(backend: Fixture.backendID, path: "/")

    private static func pane(_ backend: any VFSBackend) -> PanelViewController {
        PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: directory,
            restorationKey: nil
        )
    }

    @Test("a file already on the server is opened by its own route, not as a local path")
    func existingRemoteFileTakesTheRemoteRoute() async {
        let backend = RecordingBackend(hasFile: true)
        let pane = Self.pane(backend)

        await pane.editFile(named: "notes.txt", in: Self.directory)

        #expect(backend.statCount == 1)
        #expect(pane.transientStatusToken == 0)
        // An existing name means *open that file*: `createFile` would truncate the document the
        // user was reaching for, which is why the backend's is `O_EXCL` underneath.
        #expect(backend.createCount == 0)
    }

    @Test("a file created on the server is opened by its own route, not as a local path")
    func createdRemoteFileTakesTheRemoteRoute() async {
        let backend = RecordingBackend(hasFile: false)
        let pane = Self.pane(backend)

        await pane.editFile(named: "notes.txt", in: Self.directory)

        #expect(backend.createCount == 1)
        // Read back rather than assumed: the route is decided from an entry, and a remote one is
        // fetched and later saved against the size, time and entity tag only a `stat` carries.
        #expect(backend.statCount == 2)
        #expect(pane.transientStatusToken == 0)
    }
}

/// A remote backend that answers a `stat` either way and counts what it was asked.
///
/// Its own type rather than `RemoteFetchFixtures`' `CountingBackend`, which always finds the file
/// and does not implement `createFile` — the branch this suite exists for is the one where nothing
/// is there yet.
private final class RecordingBackend: VFSBackend, @unchecked Sendable {
    let id = Fixture.backendID
    let capabilities: VFSCapabilities = [.read, .write]

    private let lock = NSLock()
    private var present: Bool
    private var counts = (stat: 0, create: 0)

    init(hasFile: Bool) {
        present = hasFile
    }

    var statCount: Int { lock.withLock { counts.stat } }
    var createCount: Int { lock.withLock { counts.create } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        let found = lock.withLock { () -> Bool in
            counts.stat += 1
            return present
        }
        guard found else { throw VFSError.notFound(path) }
        return Fixture.entry(path.lastComponent)
    }

    func createFile(at path: VFSPath) throws {
        try lock.withLock {
            guard !present else { throw VFSError.alreadyExists(path) }
            counts.create += 1
            present = true
        }
    }
}
