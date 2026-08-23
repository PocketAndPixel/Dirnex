import Foundation
import Testing

@testable import DirnexCore

/// A server-side copy whose two ends are **different buckets** (docs/HISTORY.md ▸ After M19).
///
/// It is one `PUT` to the destination, signed once, naming the source in `x-amz-copy-source` — so
/// what this suite is really about is when that name means the object the user pointed at. A bucket
/// name is unique within a service and not between services, and the credential that signs is the
/// destination's: those are the two halves of ``S3Location/acceptsServerSideCopy(from:)``.
@Suite("S3 cross-bucket server-side copy")
struct S3CrossBucketCopyTests {
    private static func location(
        host: String = "s3.eu-north-1.amazonaws.com",
        port: Int? = nil,
        bucket: String,
        region: String = "eu-north-1",
        accessKeyID: String = "AKIAEXAMPLE",
        addressing: S3Addressing = .virtualHost,
        usesTLS: Bool = true
    ) -> S3Location {
        S3Location(
            host: host,
            port: port,
            bucket: bucket,
            region: region,
            accessKeyID: accessKeyID,
            addressing: addressing,
            usesTLS: usesTLS
        )
    }

    // MARK: - When the source's name means one thing

    @Test("two buckets on one endpoint, one key: the service can do it")
    func sameEndpointSameKey() {
        let destination = Self.location(bucket: "backup")
        #expect(destination.acceptsServerSideCopy(from: Self.location(bucket: "photos")))
        // The same bucket satisfies it too — the question is whether the name is unambiguous, not
        // whether the ends differ, and the caller is what knows which request it is making.
        #expect(destination.acceptsServerSideCopy(from: Self.location(bucket: "backup")))
    }

    @Test("a different access key id cannot, since one signature reaches both ends")
    func differentCredentialCannot() {
        let destination = Self.location(bucket: "backup")
        let source = Self.location(bucket: "photos", accessKeyID: "AKIAOTHER")
        #expect(!destination.acceptsServerSideCopy(from: source))
    }

    /// The failure worth designing against, and the only one here that is not merely a refusal: a
    /// bucket name means different things at different providers, so naming a MinIO bucket in a
    /// request to AWS addresses whatever *AWS* has under that name — which can exist, be readable,
    /// and produce a copy that succeeds with the wrong bytes under the right name.
    @Test("two different services cannot, whatever the credential says")
    func differentServiceCannot() {
        let aws = Self.location(bucket: "backup")
        let minio = Self.location(host: "192.168.1.50", port: 9000, bucket: "photos", usesTLS: false)
        #expect(!aws.acceptsServerSideCopy(from: minio))
        #expect(!minio.acceptsServerSideCopy(from: aws))

        // Same host, different port or scheme, is still a different service.
        let otherPort = Self.location(
            host: "192.168.1.50",
            port: 9001,
            bucket: "photos",
            usesTLS: false
        )
        #expect(!minio.acceptsServerSideCopy(from: otherPort))
        let secure = Self.location(host: "192.168.1.50", port: 9000, bucket: "photos")
        #expect(!minio.acceptsServerSideCopy(from: secure))
    }

    /// The one exception, resting on a documented property rather than a guess: an AWS bucket name
    /// is globally unique across every region and account, which is what `BucketAlreadyExists`
    /// means — so two regional endpoints cannot disagree about which bucket a name is.
    @Test("two AWS regions can, because an AWS bucket name is unique service-wide")
    func awsCrossRegionCan() {
        let destination = Self.location(bucket: "backup")
        let source = Self.location(
            host: "s3.us-west-2.amazonaws.com",
            bucket: "photos",
            region: "us-west-2"
        )
        #expect(destination.acceptsServerSideCopy(from: source))
        // …and the exception is Amazon's alone: a host that merely *contains* the name is not it.
        let lookalike = Self.location(host: "s3.amazonaws.com.example.net", bucket: "photos")
        #expect(!destination.acceptsServerSideCopy(from: lookalike))
    }

    /// Neither field appears in the source's name: both are about how *this* connection builds and
    /// signs its own request.
    @Test("addressing and region are not part of the question")
    func addressingAndRegionDoNotDecide() {
        let destination = Self.location(bucket: "backup")
        #expect(destination.acceptsServerSideCopy(
            from: Self.location(bucket: "photos", addressing: .path)
        ))
        #expect(destination.acceptsServerSideCopy(
            from: Self.location(bucket: "photos", region: "us-east-1")
        ))
    }

    // MARK: - The request

    @Test("the copy source names the other bucket, path-encoded, and the URL names this one")
    func argumentsNameBothBuckets() throws {
        let session = S3Session(location: Self.location(bucket: "backup"), maxTime: 30)
        let arguments = S3ProcessArguments.copyObject(
            session: session,
            sourceBucket: "photos",
            sourceKey: "holiday/a b+c.jpg",
            destinationKey: "2026/a b+c.jpg"
        )
        let header = try #require(arguments.first { $0.hasPrefix("x-amz-copy-source:") })
        #expect(header == "x-amz-copy-source: /photos/holiday/a%20b%2Bc.jpg")
        let url = try #require(arguments.last)
        #expect(url == "https://backup.s3.eu-north-1.amazonaws.com/2026/a%20b%2Bc.jpg")
    }

    /// The narrowness control on the same builder: with no source bucket it is the session's own,
    /// which is every rename and every same-bucket copy this backend has ever made.
    @Test("with no source bucket the header names this one")
    func argumentsDefaultToThisBucket() {
        let session = S3Session(location: Self.location(bucket: "backup"), maxTime: 30)
        let arguments = S3ProcessArguments.copyObject(
            session: session,
            sourceKey: "a.txt",
            destinationKey: "b.txt"
        )
        #expect(arguments.contains("x-amz-copy-source: /backup/a.txt"))
    }

    // MARK: - The backend

    @Test("a cross-bucket copy is one request, and it names the source's bucket")
    func backendCopiesAcrossBuckets() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: Self.location(bucket: "backup"), transport: transport)
        let origin = Self.location(bucket: "photos")

        try backend.copyFile(
            at: VFSPath(backend: origin.backendID, path: "/holiday/a.jpg"),
            to: VFSPath(backend: backend.id, path: "/2026/a.jpg"),
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(transport.writes == [.copyAcrossBuckets(
            sourceBucket: "photos",
            .init(sourceKey: "holiday/a.jpg", destinationKey: "2026/a.jpg")
        )])
        // Nothing was read or written through this machine, which is the whole point of the route.
        #expect(transport.downloads.isEmpty)
    }

    /// The narrowness control, and the one that costs money if it breaks: a copy inside one bucket
    /// must keep using the verb every conforming transport already implements.
    @Test("a copy inside one bucket still takes the plain verb")
    func backendKeepsSameBucketVerb() throws {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: Self.location(bucket: "backup"), transport: transport)

        try backend.copyFile(
            at: VFSPath(backend: backend.id, path: "/a.txt"),
            to: VFSPath(backend: backend.id, path: "/b.txt"),
            progress: { _ in },
            isCancelled: { false }
        )

        #expect(transport.writes == [.copy(.init(sourceKey: "a.txt", destinationKey: "b.txt"))])
    }

    @Test("a pair the service cannot name is refused here rather than guessed at")
    func backendRefusesAnIncompatiblePair() {
        let transport = FakeS3Transport()
        let backend = S3Backend(location: Self.location(bucket: "backup"), transport: transport)
        let elsewhere = Self.location(
            host: "192.168.1.50",
            port: 9000,
            bucket: "photos",
            usesTLS: false
        )

        #expect(throws: VFSError.unsupported(.copyFile)) {
            try backend.copyFile(
                at: VFSPath(backend: elsewhere.backendID, path: "/a.jpg"),
                to: VFSPath(backend: backend.id, path: "/a.jpg"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.writes.isEmpty)
    }

    /// A transport that has not implemented the cross-bucket verb must **refuse**, never fall back
    /// on its own bucket: that would copy a different object under the right name and report
    /// success, which is the one failure a caller cannot detect.
    @Test("the default transport implementation refuses instead of guessing")
    func transportDefaultRefuses() {
        let transport = SameBucketOnlyTransport()
        #expect(throws: S3CrossBucketCopyUnsupported(sourceBucket: "photos", sourceKey: "a.jpg")) {
            _ = try transport.copyObject(fromBucket: "photos", sourceKey: "a.jpg", to: "b.jpg")
        }
        #expect(transport.sameBucketCopies == 0)
    }
}

/// A transport that implements only the same-bucket copy, so the protocol's **default** for the
/// cross-bucket one is the code under test.
///
/// It cannot be `FakeS3Transport` — that one implements the new verb, which is exactly what has to
/// be absent here. The same shape, and for the same reason, as `UnconditionalTransport` in
/// `S3WriteConditionTests`.
private final class SameBucketOnlyTransport: S3Transport, @unchecked Sendable {
    private(set) var sameBucketCopies = 0

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func head(key: String) throws -> S3Response { S3Response(status: 200) }

    func upload(
        localPath: String,
        to key: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func putEmptyObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        sameBucketCopies += 1
        return S3Response(status: 200)
    }

    func deleteObject(key: String) throws -> S3Response { S3Response(status: 200) }

    func deleteObjects(keys: [String]) throws -> S3Response { S3Response(status: 200) }

    func createMultipartUpload(key: String) throws -> S3Response { S3Response(status: 200) }

    func uploadPart(
        _ part: S3PartRequest,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        S3Response(status: 200)
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        S3Response(status: 200)
    }
}
