import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Which panes Synchronize Directories will take, once a side no longer has to be on this disk
/// (PLAN.md §M25 Slice 5c), and which it still refuses.
///
/// The panes are headless — the view is never loaded and there is no `host` — so what is measured is
/// the gate itself rather than anything a sheet does with the answer.
@Suite("Sync: which panes can take part")
@MainActor
struct SyncReachTests {
    private static let sftp = SFTPLocation(host: "example.test", username: "oleg")
    private static let bucket = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "photos",
        region: "eu-north-1",
        accessKeyID: "AKIA"
    )
    private static let account = S3Account(
        host: "s3.eu-north-1.amazonaws.com",
        region: "eu-north-1",
        accessKeyID: "AKIA"
    )

    private static func pane(
        at path: VFSPath,
        capabilities: VFSCapabilities = [.read, .write]
    ) -> PanelViewController {
        let backend = RoutingBackend(perPath: [path: capabilities])
        let vc = PanelViewController(
            backend: backend,
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        vc.panel = Panel(model: DirectoryModel(listing: DirectoryListing(path: path, entries: [])))
        return vc
    }

    // MARK: - The widened gate

    @Test("a connected server's directory can take part")
    func remoteDirectoryCanSync() {
        let path = VFSPath(backend: .sftp(Self.sftp), path: "/srv/backup")
        #expect(PanelViewController.canSync(Self.pane(at: path)))
    }

    @Test("a bucket's directory can take part")
    func bucketDirectoryCanSync() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/2026")
        #expect(PanelViewController.canSync(Self.pane(at: path)))
    }

    @Test("this disk is unchanged")
    func localStillSyncs() {
        #expect(PanelViewController.canSync(Self.pane(at: .local("/Users/oleg/docs"))))
    }

    // MARK: - What stays refused, and why each one is its own reason

    /// An account's rows are **buckets** and there is no verb for putting a file in an account, so
    /// it is `isRemoteConnection` and is not a folder.
    @Test("an S3 account pane is a connection and still not a folder")
    func s3AccountIsRefused() {
        let path = VFSPath(backend: .s3Account(Self.account), path: "/")
        #expect(!PanelViewController.canSync(Self.pane(at: path)))
    }

    /// A sync deletes, and deleting an archive member rewrites the whole container with nothing the
    /// journal can undo — a stated limit rather than a missing branch.
    @Test("an archive is refused")
    func archiveIsRefused() {
        let path = VFSPath(backend: .archive(forArchiveAt: "/tmp/a.zip"), path: "/docs")
        #expect(!PanelViewController.canSync(Self.pane(at: path)))
    }

    @Test("a virtual listing has no directory to synchronize")
    func virtualListingsAreRefused() {
        for backend in [VFSBackendID.search, .trash, .icloud] {
            let path = VFSPath(backend: backend, path: "/")
            #expect(!PanelViewController.canSync(Self.pane(at: path)), "\(backend) was accepted")
        }
    }

    @Test("a location the pane cannot read is refused whatever its backend")
    func unreadableIsRefused() {
        let path = VFSPath(backend: .sftp(Self.sftp), path: "/srv/backup")
        #expect(!PanelViewController.canSync(Self.pane(at: path, capabilities: [])))
    }

    // MARK: - Which side may be written to

    /// The discriminating case for `capabilities(for:)` over `capabilities`: the pane's backend is
    /// backend-wide writable — a `CompositeBackend`'s always is, since that set is the *local*
    /// backend's — while this particular bucket is read-only. Asking the shorter way answers `true`
    /// here and offers a mirror that would fail one file at a time inside the queue.
    @Test("a read-only location cannot be written to, whatever the backend says overall")
    func readOnlyLocationAcceptsNoChanges() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/2026")
        #expect(!PanelViewController.acceptsChanges(Self.pane(at: path, capabilities: [.read])))
        #expect(PanelViewController.acceptsChanges(Self.pane(at: path)))
    }

    /// Writable *and* nowhere for a file to land: an account carries `.write` because F7 there
    /// creates a bucket, which is not the same as receiving one.
    @Test("an account is writable and still receives no files")
    func accountAcceptsNoChanges() {
        let path = VFSPath(backend: .s3Account(Self.account), path: "/")
        #expect(!PanelViewController.acceptsChanges(Self.pane(at: path)))
    }
}

/// A backend whose per-path answer differs from its backend-wide one, which is the shape a
/// `CompositeBackend` has and the reason a gate must ask `capabilities(for:)`.
private struct RoutingBackend: VFSBackend {
    let perPath: [VFSPath: VFSCapabilities]

    var id: VFSBackendID { .local }
    /// What the local backend answers, which is what a composite reports for *every* path.
    var capabilities: VFSCapabilities { [.read, .write, .trash, .watch] }

    func capabilities(for path: VFSPath) -> VFSCapabilities { perPath[path] ?? [] }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}
