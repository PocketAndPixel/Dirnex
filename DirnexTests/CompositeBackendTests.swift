import DirnexCore
import Testing

@testable import Dirnex

/// The pane's routing backend reports capabilities *per path* so the panel grays operations
/// off the current location's real backend (PLAN.md §M5 "capability degradation"). Local paths
/// keep the full disk capability set; a connected SFTP account is writable but Trash-less and
/// clone-less (so a delete degrades to a confirmed permanent one); a virtual location (a browsed
/// `archive:…` tree or a search-results listing) — and an SFTP path with no live connection —
/// degrades to read-only, its `deleteStrategy` `.unsupported`, so New Folder / rename / delete gray
/// out. (An archive's *writes* travel a separate rewrite path gated by `isWritableArchive`, not
/// these VFS capabilities.)
@Suite("CompositeBackend capabilities")
struct CompositeBackendTests {
    private let backend = CompositeBackend(local: LocalBackend())

    @Test("a local path carries the full local capability set")
    func localPathIsFullyCapable() {
        let caps = backend.capabilities(for: .local("/Users/me"))
        #expect(caps.contains(.write))
        #expect(caps.contains(.trash))
        #expect(caps.contains(.clone))
        #expect(caps.contains(.rename))
        #expect(caps.deleteStrategy == .trash)
    }

    @Test("an archive path degrades to read-only")
    func archivePathIsReadOnly() {
        let inside = VFSPath(backend: .archive(forArchiveAt: "/Users/me/pkg.zip"), path: "/a/b.txt")
        let caps = backend.capabilities(for: inside)
        #expect(caps == .read)
        #expect(!caps.contains(.write))
        #expect(caps.deleteStrategy == .unsupported)
    }

    @Test("a search-results path degrades to read-only")
    func searchPathIsReadOnly() {
        let results = VFSPath(backend: .search, path: "/query")
        #expect(backend.capabilities(for: results) == .read)
        #expect(backend.capabilities(for: results).deleteStrategy == .unsupported)
    }

    @Test("an sftp path with no live connection reports read-only, so writes gray out")
    func unconnectedSFTPPathIsReadOnly() {
        let remote = VFSPath(backend: .sftp(SFTPLocation(host: "h", username: "u")), path: "/home/u")
        #expect(backend.capabilities(for: remote) == .read)
        #expect(backend.capabilities(for: remote).deleteStrategy == .unsupported)
    }

    @Test("a connected sftp path is writable but Trash-less, so a delete degrades to permanent")
    func connectedSFTPPathIsWritable() {
        let location = SFTPLocation(host: "h", username: "u")
        // Registering a connection doesn't touch the network — it just installs the backend so the
        // pane can route to it; the capabilities are then the SFTP backend's own.
        backend.connectSFTP(location: location, authentication: .key(identityFile: "/tmp/key"))
        let remote = VFSPath(backend: .sftp(location), path: "/home/u")
        let caps = backend.capabilities(for: remote)
        #expect(caps == [.read, .write, .rename])
        #expect(!caps.contains(.trash))
        #expect(!caps.contains(.clone))
        #expect(caps.deleteStrategy == .permanent)
    }

    @Test("listing an sftp path with no connection reports a clear not-connected error")
    func unconnectedSFTPPathThrows() {
        // Routing recognizes the sftp id but there's no registered connection — a helpful error,
        // not a crash or a mis-route to the local backend.
        let remote = VFSPath(backend: .sftp(SFTPLocation(host: "h", username: "u")), path: "/home/u")
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: remote)
        }
    }

    // MARK: - S3

    private static let bucket = S3Location(
        host: "s3.eu-central-1.amazonaws.com",
        bucket: "photos",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    /// The two halves now genuinely differ, which is what makes this worth asserting: an
    /// unconnected bucket grays its writes, and a connected one offers them. Until the write half
    /// landed both sides of that fallback were the same value, so nothing could tell a wired
    /// lookup from a fallback that happened to agree with it.
    @Test("an s3 path is writable once connected, and read-only before")
    func s3PathBecomesWritableWhenConnected() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/docs")
        // No credential, so nothing can be written — gray it rather than offer it.
        #expect(backend.capabilities(for: path) == .read)

        // Registering a connection touches no network — it installs the backend so the pane can
        // route to it, and the credential is never asked for again per page.
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        let caps = backend.capabilities(for: path)
        #expect(caps.contains(.read))
        #expect(caps.contains(.write))
        // The set the *pane* reads, which is the whole point of routing per path: F2 and its menu
        // item both ask this one, so a bucket that renames must say so here or the item grays over
        // a working key (`RenameReachTests`).
        #expect(caps.contains(.rename))
        // Trash-less and clone-less: F8 degrades to the confirmed permanent delete, and a copy
        // never takes the instant-clone path a real filesystem offers.
        #expect(!caps.contains(.trash))
        #expect(!caps.contains(.clone))
        #expect(caps.deleteStrategy == .permanent)
    }

    @Test("listing an s3 path with no connection reports a clear not-connected error")
    func unconnectedS3PathThrows() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/docs")
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: path)
        }
    }

    /// The search shortcut has to be **routed**, not inherited (PLAN.md §M22 Slice 3).
    ///
    /// `VFSBackend.subtreeListing` defaults to `nil`, meaning "no shortcut, walk instead" — so a
    /// composite that forgot to forward it would compile, behave correctly, return the same rows,
    /// and quietly cost one billed request per folder over a bucket that can answer the whole
    /// subtree in one. There is no symptom on screen, which is why the routing is asserted rather
    /// than assumed.
    ///
    /// Asserted through an **unconnected** bucket precisely because it touches no network: the
    /// forward reaches the routing lookup, which says "not connected", where the inherited default
    /// answers `nil` without asking anybody. Those are the two behaviours to tell apart.
    @Test(
        "a subtree listing routes to the path's own backend instead of the walk-everything default"
    )
    func subtreeListingIsRouted() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/docs")
        #expect(throws: (any Error).self) {
            _ = try backend.subtreeListing(at: path, isCancelled: { false })
        }
    }

    /// The narrowness control: routing it does not mean answering it. The local disk has no
    /// shortcut, so it must still say `nil` and be walked — a forward that invented a subtree
    /// listing for everything would pass the test above and break every other search.
    @Test("a local path still reports no shortcut, so it is walked")
    func localPathHasNoSubtreeShortcut() throws {
        #expect(try backend.subtreeListing(at: .local("/tmp"), isCancelled: { false }) == nil)
    }

    /// A connection is keyed by the bucket descriptor rather than by the endpoint, so connecting
    /// one bucket does not silently make its neighbours routable — the ordinary case, since one key
    /// commonly reaches several buckets on the same host. Keyed by host, the second listing would
    /// reach for the network instead of saying it is not connected.
    @Test("connecting one bucket does not connect its neighbours on the same endpoint")
    func bucketsAreIndependentConnections() {
        let other = S3Location(
            host: Self.bucket.host,
            bucket: "archive",
            region: Self.bucket.region,
            accessKeyID: Self.bucket.accessKeyID
        )
        backend.connectS3(location: Self.bucket, secretAccessKey: "a")
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: VFSPath(backend: .s3(other), path: "/"))
        }
    }

    // MARK: - Who can carry a precondition

    /// The lookup a guarded save-back routes through (PLAN.md §M21 Slice 18), and the reason it is
    /// a lookup rather than a test on the path: `path.backend.isS3` is `true` for a bucket nobody
    /// has connected, where there is no credential to sign with and nothing to write through.
    @Test("a connected bucket can carry a precondition, and an unconnected one cannot")
    func conditionalWriterNeedsAConnection() {
        let path = VFSPath(backend: .s3(Self.bucket), path: "/docs/notes.txt")
        #expect(backend.conditionalWriter(for: path) == nil)

        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        #expect(backend.conditionalWriter(for: path) != nil)
    }

    /// The narrowness controls, and they are the half that matters: a lookup that answered for
    /// everything would send an `If-Match` down a path that cannot carry one, and the seam beneath
    /// it throws rather than dropping the header — so the failure would be a save-back that stops
    /// working over SFTP, FTP and the local disk alike.
    @Test("nothing but a bucket answers, connected or not")
    func conditionalWriterIsNarrow() {
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        backend.connectS3Account(account: Self.bucket.account, secretAccessKey: "secret")

        #expect(backend.conditionalWriter(for: .local("/Users/me/notes.txt")) == nil)
        #expect(backend.conditionalWriter(
            for: VFSPath(backend: .s3Account(Self.bucket.account), path: "/photos")
        ) == nil)
        #expect(backend.conditionalWriter(
            for: VFSPath(backend: .sftp(SFTPLocation(host: "h", username: "u")), path: "/home/u/a")
        ) == nil)
        #expect(backend.conditionalWriter(
            for: VFSPath(backend: .archive(forArchiveAt: "/Users/me/pkg.zip"), path: "/a/b.txt")
        ) == nil)
    }

    // MARK: - Accounts

    /// An account pane is writable in a narrower sense than a bucket's — its writes create and
    /// delete *buckets* — and it must not advertise `.rename`, which S3 cannot do to a bucket at
    /// any level. An unconnected one grays its writes exactly as an unconnected bucket does.
    @Test("an s3 account is writable once connected, and never renameable")
    func s3AccountBecomesWritableWhenConnected() {
        let account = Self.bucket.account
        let path = VFSPath(backend: .s3Account(account), path: "/")
        #expect(backend.capabilities(for: path) == .read)

        backend.connectS3Account(account: account, secretAccessKey: "secret")
        let caps = backend.capabilities(for: path)
        #expect(caps.contains(.read))
        #expect(caps.contains(.write))
        #expect(!caps.contains(.rename))
        #expect(!caps.contains(.trash))
        #expect(caps.deleteStrategy == .permanent)
    }

    /// The two connections are independent in **both** directions, which is what walking out of a
    /// bucket into its account and back down into another one rests on. They are keyed by
    /// descriptors that cannot collide — `s3://` against `s3a://` — so neither registration can
    /// stand in for the other, and connecting an account must not quietly make every bucket on the
    /// endpoint routable without a credential of its own.
    @Test("connecting an account connects neither its buckets nor the other way round")
    func accountsAndBucketsAreIndependentConnections() {
        let account = Self.bucket.account
        backend.connectS3Account(account: account, secretAccessKey: "a")
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: VFSPath(backend: .s3(Self.bucket), path: "/"))
        }

        let fresh = CompositeBackend(local: LocalBackend())
        fresh.connectS3(location: Self.bucket, secretAccessKey: "a")
        #expect(throws: (any Error).self) {
            try fresh.listDirectory(at: VFSPath(backend: .s3Account(account), path: "/"))
        }
    }
}

/// The routing of Get Info's **write** half (PLAN.md §M25 Slice 5).
///
/// Its own suite because what it pins is not a capability but a **forward**, and a missing forward
/// here has no symptom at all: the composite would inherit `VFSBackend`'s default, every remote
/// panel would come up read-only, and nothing would log, fail or look wrong. That is the shape M22
/// Slice 3 shipped once — `subtreeListing` routed nowhere, so every search silently took the slow
/// path and only the bill said so.
///
/// Registering a connection costs no round trip: `connectSFTP` builds a transport and files it under
/// a descriptor, and the network does not happen until a listing. So this needs no server.
@Suite("CompositeBackend ▸ remote attribute writing")
struct CompositeBackendMetadataRoutingTests {
    private let location = SFTPLocation(host: "srv.example", username: "oleg")

    private func connected() -> (CompositeBackend, VFSPath) {
        let composite = CompositeBackend(local: LocalBackend())
        composite.connectSFTP(location: location, authentication: .key(identityFile: "/dev/null"))
        return (composite, VFSPath(backend: .sftp(location), path: "/home/oleg/a.txt"))
    }

    @Test("a connected SFTP row's editable fields come from its own connection")
    func routesToTheOwningConnection() {
        // `.changeMode` is SFTP's answer and `[]` is the inherited default, so the two are
        // distinguishable — which is what makes this a test of the forward rather than of a shape
        // both branches happen to share.
        let (composite, path) = connected()
        #expect(composite.editableMetadata(at: path) == .changeMode)
    }

    /// The narrowness control. Answering for everything would be as wrong as answering for nothing:
    /// a local row takes the full editing panel and must never be routed here, and an archive member
    /// has no verb at all.
    @Test("a local row and an archive member offer nothing")
    func nonRemoteRowsOfferNothing() {
        let (composite, _) = connected()
        #expect(composite.editableMetadata(at: .local("/tmp/a.txt")).isEmpty)
        #expect(composite.editableMetadata(
            at: VFSPath(backend: .archive(forArchiveAt: "/tmp/t.zip"), path: "/a.txt")
        ).isEmpty)
    }

    @Test("a path on no connection offers nothing rather than raising")
    func unconnectedPathIsQuiet() {
        // An unreachable connection is a reason to show the read-only panel, not to refuse to
        // describe the row — Get Info's read half must keep working when its write half cannot.
        let composite = CompositeBackend(local: LocalBackend())
        let path = VFSPath(backend: .sftp(location), path: "/home/oleg/a.txt")
        #expect(composite.editableMetadata(at: path).isEmpty)
    }

    @Test("a write on no connection is refused rather than silently doing nothing")
    func unconnectedWriteThrows() {
        let composite = CompositeBackend(local: LocalBackend())
        let path = VFSPath(backend: .sftp(location), path: "/home/oleg/a.txt")
        #expect(throws: (any Error).self) {
            try composite.applyMetadata([.setMode(POSIXPermissions(rawValue: 0o644))], at: path)
        }
    }
}
