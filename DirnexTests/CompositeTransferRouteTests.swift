import DirnexCore
import Testing

@testable import Dirnex

/// Who moves a copy's bytes (docs/HISTORY.md ▸ After M19) — the one routing decision the pane's backend makes
/// from **two** paths rather than one.
///
/// It is asserted rather than exercised because only the decision can be: running any route here
/// would spawn `sftp` or `curl`. The decision is also the half that fails silently — a pair sent to
/// a backend that cannot serve it comes back as "Copying directly between remote locations isn't
/// supported", which is what F5 from a bucket to a server used to say, and a pair *needlessly*
/// staged would download and re-upload a file S3 can copy inside itself.
///
/// Registering a connection touches no network: it installs the backend so routing can find it.
@Suite("CompositeBackend transfer routing")
struct CompositeTransferRouteTests {
    private let backend = CompositeBackend(local: LocalBackend())
    private static let alpha = SFTPLocation(host: "alpha.example", username: "u")
    private static let beta = SFTPLocation(host: "beta.example", username: "u")
    private static let bucket = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "photos",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func sftp(_ location: SFTPLocation, _ path: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: path)
    }

    private func s3(_ path: String) -> VFSPath {
        VFSPath(backend: .s3(Self.bucket), path: path)
    }

    /// The route, reduced to what a test can compare: which backend, or which pair.
    private func route(_ source: VFSPath, _ destination: VFSPath) throws -> String {
        switch try backend.transferRoute(from: source, to: destination) {
        case let .direct(mover): "direct \(mover.id)"
        case let .staged(from, into): "staged \(from.id) → \(into.id)"
        }
    }

    // MARK: - One backend can do it

    @Test("a local copy stays on the local backend")
    func localToLocalIsDirect() throws {
        #expect(try route(.local("/tmp/a"), .local("/tmp/b")) == "direct local")
    }

    @Test("an upload is the destination account's, a download the source account's")
    func oneLocalEndRoutesToTheAccount() throws {
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        let remote = VFSBackendID.sftp(Self.alpha)
        #expect(try route(.local("/tmp/a"), sftp(Self.alpha, "/home/u/a")) == "direct \(remote)")
        #expect(try route(sftp(Self.alpha, "/home/u/a"), .local("/tmp/a")) == "direct \(remote)")
    }

    /// The narrowness control, and the one that costs money if it breaks: a copy with both ends in
    /// one bucket is `x-amz-copy-source`, so the bytes must never come through this machine.
    @Test("a copy inside one bucket is handed to S3, not staged")
    func sameBucketIsServerSide() throws {
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        #expect(try route(s3("/a.jpg"), s3("/b.jpg")) == "direct \(VFSBackendID.s3(Self.bucket))")
    }

    // MARK: - Nobody can, so it is staged

    @Test("two different accounts are staged through this disk")
    func twoAccountsAreStaged() throws {
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        backend.connectSFTP(location: Self.beta, authentication: .key(identityFile: "/tmp/key"))
        let expected = "staged \(VFSBackendID.sftp(Self.alpha)) → \(VFSBackendID.sftp(Self.beta))"
        #expect(try route(sftp(Self.alpha, "/home/u/a"), sftp(Self.beta, "/home/u/a")) == expected)
    }

    @Test("a bucket to a server is staged")
    func acrossProtocolsIsStaged() throws {
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        let expected = "staged \(VFSBackendID.s3(Self.bucket)) → \(VFSBackendID.sftp(Self.alpha))"
        #expect(try route(s3("/a.jpg"), sftp(Self.alpha, "/home/u/a.jpg")) == expected)
    }

    /// The case that looks like it should be direct and is not: SFTP has no copy verb at all, so
    /// duplicating a file *within one account* has no more expression there than one between two.
    /// This is the pair a router keyed on "same backend id" would hand straight back to a backend
    /// that refuses it.
    @Test("a duplicate inside one SFTP account is staged too")
    func sameAccountWithoutACopyVerbIsStaged() throws {
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        let account = VFSBackendID.sftp(Self.alpha)
        #expect(
            try route(sftp(Self.alpha, "/a/x"), sftp(Self.alpha, "/b/x"))
                == "staged \(account) → \(account)"
        )
    }

    // MARK: - Nothing is invented

    /// Routing a pair is not the same as being able to serve it: an account nobody connected has no
    /// credential, and the honest answer is to say so rather than to stage bytes nothing can fetch.
    @Test("an unconnected account reports not-connected instead of a route")
    func unconnectedAccountThrows() {
        backend.connectSFTP(location: Self.beta, authentication: .key(identityFile: "/tmp/key"))
        #expect(throws: (any Error).self) {
            _ = try backend.transferRoute(
                from: sftp(Self.alpha, "/home/u/a"),
                to: sftp(Self.beta, "/home/u/a")
            )
        }
    }
}
