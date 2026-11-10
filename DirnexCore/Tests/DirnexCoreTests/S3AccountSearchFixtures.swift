import Foundation

@testable import DirnexCore

/// The buckets of one account, each behind a fake transport of its own (PLAN.md §M38 Slice 5).
///
/// Keyed by the **whole location** rather than by the bucket name, because which location was asked
/// is half of what the account search is about: a bucket in another region is reached at a
/// different host, and a path-style retry is a different location with the same bucket. A fake keyed
/// by name would answer the wrong-region request and the corrected one alike, and a search that never
/// re-aimed would pass.
final class FakeBucketRouter: @unchecked Sendable {
    /// One fake per location, created on first use so a test sets up only the buckets it is about.
    private(set) var fakes: [String: FakeS3Transport] = [:]
    /// Every location a transport was built for, in order — one entry per attempt, plus one for the
    /// backend that lists the rest of a bucket once it has been reached.
    private(set) var asked: [S3Location] = []

    func fake(for location: S3Location) -> FakeS3Transport {
        if let fake = fakes[location.descriptor] { return fake }
        let fake = FakeS3Transport()
        fakes[location.descriptor] = fake
        return fake
    }

    func transport(_ location: S3Location) -> any S3Transport {
        asked.append(location)
        return fake(for: location)
    }

    /// Every listing request made, across every bucket and location.
    var listRequestCount: Int { fakes.values.map(\.listRequests.count).reduce(0, +) }
}

/// Listings for the account search, in the shape the captured `ListBucketResult` and
/// `ListAllMyBucketsResult` pages have (`S3Fixtures`, `S3AccountBackendTests`).
///
/// Generated rather than captured, because what these tests are about is **counts** — how many keys
/// a bound lets through, which page a search stops before — and a captured page has whatever count
/// the bucket happened to hold. The element shapes are the captured ones.
enum S3AccountSearchFixtures {
    static let account = S3Account(
        host: "s3.us-east-1.amazonaws.com",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    /// A third-party endpoint: path-style, no region in its host.
    static let compatibleAccount = S3Account(
        host: "s3.lax.sharktech.net",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .path
    )

    /// An account backend whose bucket list is `buckets`, each with the region given beside it.
    static func accountBackend(
        _ buckets: [(name: String, region: String?)],
        account: S3Account = account
    ) -> (S3AccountBackend, FakeS3AccountTransport) {
        let transport = FakeS3AccountTransport()
        transport.listPages = [.ok(bucketList(buckets))]
        return (S3AccountBackend(account: account, transport: transport), transport)
    }

    static func bucketList(_ buckets: [(name: String, region: String?)]) -> String {
        let rows = buckets.map { bucket in
            let region = bucket.region.map { "<BucketRegion>\($0)</BucketRegion>" } ?? ""
            return "<Bucket><Name>\(bucket.name)</Name>"
                + "<CreationDate>2026-08-13T12:00:27.000Z</CreationDate>\(region)</Bucket>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <Owner><ID>da0b957a94e834f5</ID><DisplayName></DisplayName></Owner>\
        <Buckets>\(rows.joined())</Buckets></ListAllMyBucketsResult>
        """
    }

    /// One page of a delimiter-less listing holding `keys`, with a next token when `next` is given.
    static func page(_ keys: [String], bucket: String = "bucket", next: String? = nil) -> S3Response {
        let contents = keys.map { key in
            "<Contents><Key>\(key)</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>"
                + "<ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>12</Size>"
                + "<StorageClass>STANDARD</StorageClass></Contents>"
        }
        let token = next.map { "<NextContinuationToken>\($0)</NextContinuationToken>" } ?? ""
        return .ok("""
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>\(bucket)</Name>\
        <Prefix></Prefix>\(token)<KeyCount>\(keys.count)</KeyCount><MaxKeys>1000</MaxKeys>\
        <EncodingType>url</EncodingType><IsTruncated>\(next != nil)</IsTruncated>\
        \(contents.joined())</ListBucketResult>
        """)
    }

    /// The 301 AWS answers a bucket addressed through the wrong region with, naming the right one in
    /// the header it sends on every response (measured 2026-08-12).
    static func wrongRegion(naming region: String) -> S3Response {
        S3Response(status: 301, body: Data(S3Fixtures.wrongRegion.utf8), bucketRegion: region)
    }

    /// A key allowed to list buckets and refused inside this one.
    static let accessDenied = S3Response(status: 403, body: Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied</Message>\
    <RequestId>BJ28272AE9ZPVRMF</RequestId><HostId>SiTuTP6H9RVunH8D</HostId></Error>
    """.utf8))

    /// A query every generated key matches: its name contains `.`.
    static func everyFile() throws -> SearchPredicate {
        try SearchPredicate(FileQuery(nameContains: "."), answering: .listed)
    }
}
