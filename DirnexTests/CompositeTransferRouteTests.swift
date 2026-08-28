import DirnexCore
import Foundation
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
    /// A second bucket on the same endpoint under the same key — the pair the service can copy
    /// between without the bytes coming here.
    private static let sibling = S3Location(
        host: "s3.eu-north-1.amazonaws.com",
        bucket: "backup",
        region: "eu-north-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private func sftp(_ location: SFTPLocation, _ path: String) -> VFSPath {
        VFSPath(backend: .sftp(location), path: path)
    }

    private func s3(_ path: String) -> VFSPath {
        VFSPath(backend: .s3(Self.bucket), path: path)
    }

    private func s3(_ location: S3Location, _ path: String) -> VFSPath {
        VFSPath(backend: .s3(location), path: path)
    }

    /// The route, reduced to what a test can compare: which backend, or which pair.
    private func route(_ source: VFSPath, _ destination: VFSPath) throws -> String {
        switch try backend.transferRoute(from: source, to: destination) {
        case let .direct(mover): "direct \(mover.id)"
        case let .serverSide(mover): "serverSide \(mover.id)"
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

    // MARK: - One account, one server-side copy

    /// The pair that changed at M25 Slice 3, and the one whose failure has no symptom: OpenSSH's
    /// `copy-data` extension is a real server-side `cp` — 64 MiB in 0.09 s against 0.5 s staged over
    /// *loopback* — so a router that went on staging this would produce identical files, identical
    /// rows and a milestone that is inert with every test still green.
    ///
    /// It is `serverSide` rather than `direct` because it can be refused: a server need not
    /// advertise the extension and nothing asks in advance, so the route has to carry a fallback.
    @Test("a duplicate inside one SFTP account is offered to the server")
    func sameAccountIsServerSide() throws {
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        let account = VFSBackendID.sftp(Self.alpha)
        #expect(
            try route(sftp(Self.alpha, "/a/x"), sftp(Self.alpha, "/b/x")) == "serverSide \(account)"
        )
    }

    /// The composite forwards the question rather than inheriting the `false` default — the seam
    /// whose failure is silent, since a pane holds a composite and every same-account copy would
    /// quietly go on being staged.
    @Test("the composite answers for the account that owns both ends")
    func compositeForwardsTheAttemptQuestion() {
        backend.connectSFTP(location: Self.alpha, authentication: .key(identityFile: "/tmp/key"))
        #expect(backend.mayAttemptInternalCopy(
            from: sftp(Self.alpha, "/a/x"),
            to: sftp(Self.alpha, "/b/x")
        ))
        // The narrowness control: a pair the account does not own, and a backend with no such verb.
        #expect(
            !backend.mayAttemptInternalCopy(from: sftp(Self.alpha, "/a/x"), to: .local("/tmp/x"))
        )
        #expect(!backend.mayAttemptInternalCopy(from: .local("/tmp/a"), to: .local("/tmp/b")))
    }

    /// FTP is the control that keeps "same account" from becoming the rule: `curl` has a download
    /// and an upload and no copy verb of any kind, so this pair is still staged.
    @Test("a duplicate inside one FTP account is still staged")
    func sameFTPAccountIsStaged() throws {
        let ftp = FTPLocation(host: "ftp.example", username: "u")
        backend.connectFTP(location: ftp, authentication: .password, password: "p")
        let account = VFSBackendID.ftp(ftp)
        #expect(
            try route(
                VFSPath(backend: account, path: "/a/x"),
                VFSPath(backend: account, path: "/b/x")
            ) == "staged \(account) → \(account)"
        )
    }

    // MARK: - Two buckets, one service

    /// The service copies between its own buckets (`x-amz-copy-source`), so staging would carry
    /// every byte through this machine twice to produce a request S3 would have made itself.
    @Test("two buckets on one endpoint are copied by the service")
    func twoBucketsOnOneEndpointAreServerSide() throws {
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        backend.connectS3(location: Self.sibling, secretAccessKey: "secret")
        #expect(
            try route(s3("/a.jpg"), s3(Self.sibling, "/a.jpg"))
                == "serverSide \(VFSBackendID.s3(Self.sibling))"
        )
    }

    /// Only the **destination** performs it: one `PUT`, signed once, with its credentials doing the
    /// reading. The source is named in a header rather than fetched.
    @Test("the destination's connection is the one that has to be live")
    func theDestinationIsTheMover() throws {
        backend.connectS3(location: Self.sibling, secretAccessKey: "secret")
        #expect(
            try route(s3("/a.jpg"), s3(Self.sibling, "/a.jpg"))
                == "serverSide \(VFSBackendID.s3(Self.sibling))"
        )
    }

    /// One signature reaches both ends, so two keys are two connections the service will not join.
    @Test("two buckets under different keys are staged instead")
    func differentCredentialsAreStaged() throws {
        let other = S3Location(
            host: Self.bucket.host,
            bucket: "archive",
            region: Self.bucket.region,
            accessKeyID: "AKIAOTHER"
        )
        backend.connectS3(location: Self.bucket, secretAccessKey: "a")
        backend.connectS3(location: other, secretAccessKey: "b")
        #expect(
            try route(s3("/a.jpg"), VFSPath(backend: .s3(other), path: "/a.jpg"))
                == "staged \(VFSBackendID.s3(Self.bucket)) → \(VFSBackendID.s3(other))"
        )
    }

    /// The one that matters most, because its failure is a copy that *succeeds* with the wrong
    /// bytes: a bucket name means different things at different providers, so a pair on two
    /// services is staged however identical the credentials look.
    @Test("two buckets on different services are staged, not named to each other")
    func differentServicesAreStaged() throws {
        let elsewhere = S3Location(
            host: "192.168.1.50",
            port: 9000,
            bucket: "photos",
            region: Self.bucket.region,
            accessKeyID: Self.bucket.accessKeyID,
            addressing: .path,
            usesTLS: false
        )
        backend.connectS3(location: Self.bucket, secretAccessKey: "secret")
        backend.connectS3(location: elsewhere, secretAccessKey: "secret")
        #expect(
            try route(VFSPath(backend: .s3(elsewhere), path: "/a.jpg"), s3("/a.jpg"))
                == "staged \(VFSBackendID.s3(elsewhere)) → \(VFSBackendID.s3(Self.bucket))"
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

/// What happens when the service **refuses** the copy it was routed (docs/HISTORY.md ▸ After M19).
///
/// The cross-bucket route is the one decision here that can be wrong for reasons neither side can
/// see in advance — S3 caps `CopyObject` at 5 GiB, an S3-compatible endpoint need not offer a
/// cross-bucket copy at all, and a bucket policy can allow the read through one connection and not
/// the other. All of those are recoverable by moving the bytes ourselves, so the route degrades to
/// staging rather than reporting a failure the user cannot act on.
///
/// Both requests fail here — the endpoint is a port with nothing on it, which answers in
/// microseconds — so what the test reads is **which path is reported**: a refused server-side copy
/// names the *destination* (its `PUT`), while the staged download that follows names the *source*.
/// That is the only observable that separates "it fell back" from "it gave up", and it needs no
/// server to see.
@Suite("CompositeBackend server-side copy fallback")
struct CompositeServerSideFallbackTests {
    private static func unreachable(bucket: String) -> S3Location {
        S3Location(
            host: "127.0.0.1",
            port: 1,
            bucket: bucket,
            region: "us-east-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: .path,
            usesTLS: false
        )
    }

    @Test("a refused cross-bucket copy stages the bytes instead of reporting")
    func refusedCopyIsStaged() async throws {
        // Off the cooperative pool: both legs block on a `curl` subprocess, which a test body may
        // not do — see ``offCooperativePool``.
        try await offCooperativePool {
            let backend = CompositeBackend(local: LocalBackend())
            let from = Self.unreachable(bucket: "photos")
            let into = Self.unreachable(bucket: "backup")
            backend.connectS3(location: from, secretAccessKey: "secret")
            backend.connectS3(location: into, secretAccessKey: "secret")
            let source = VFSPath(backend: .s3(from), path: "/a.jpg")
            let destination = VFSPath(backend: .s3(into), path: "/a.jpg")

            #expect(throws: VFSError.io(path: source, code: EIO)) {
                try backend.copyFile(
                    at: source,
                    to: destination,
                    progress: { _ in },
                    isCancelled: { false }
                )
            }
        }
    }

    /// The narrowness control: a **cancelled** copy is not a refusal, and reports as one.
    ///
    /// What it pins is the outcome, not the branch that produces it — measured, this passes with
    /// `copyFile`'s explicit cancellation arm removed, because `RelayCopy` checks cancellation
    /// before it stages anything. Both spellings are correct today; only one of them stays correct
    /// if that first line ever moves, and neither is visible from here.
    @Test("a cancelled copy reports cancellation rather than a failed transfer")
    func cancellationIsNotAFallback() async throws {
        try await offCooperativePool {
            let backend = CompositeBackend(local: LocalBackend())
            let from = Self.unreachable(bucket: "photos")
            let into = Self.unreachable(bucket: "backup")
            backend.connectS3(location: from, secretAccessKey: "secret")
            backend.connectS3(location: into, secretAccessKey: "secret")

            #expect(throws: CancellationError.self) {
                try backend.copyFile(
                    at: VFSPath(backend: .s3(from), path: "/a.jpg"),
                    to: VFSPath(backend: .s3(into), path: "/a.jpg"),
                    progress: { _ in },
                    isCancelled: { true }
                )
            }
        }
    }
}
