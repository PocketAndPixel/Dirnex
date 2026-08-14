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
