import Foundation
import Testing

@testable import DirnexCore

/// The account-level half of the S3 backend (PLAN.md §M21 Slice 7): the service URL a bucket-less
/// request is built on, the `ListAllMyBuckets` parser, and the page loop over it.
///
/// **These fixtures are constructed from the S3 API reference, not captured**, and that is stated
/// here as well as on ``S3BucketListParser`` because it changes what a green run means: there is no
/// public account to list, so unlike the object-listing suite — whose bytes came off real buckets —
/// this one proves the parser reads the documented shape and tolerates the variations, not that it
/// agrees with what AWS sends.
@Suite("S3 account and bucket list")
struct S3BucketListTests {
    private let account = S3Account(
        host: "s3.eu-central-1.amazonaws.com",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    // MARK: - The account URL

    @Test("a service request is aimed at the endpoint, never at a bucket-prefixed host")
    func serviceURLHasNoBucket() {
        // The whole reason `S3Account` exists: under virtual-host addressing an `S3Location`'s
        // origin spells the bucket into the host, where `GET /` is a listing of that one bucket's
        // objects rather than an error — a well-formed answer to a different question.
        let location = S3Location(
            host: "s3.eu-central-1.amazonaws.com",
            bucket: "photos",
            region: "eu-central-1",
            accessKeyID: "AKIAEXAMPLE",
            addressing: .virtualHost
        )
        #expect(location.origin == "https://photos.s3.eu-central-1.amazonaws.com")
        #expect(location.account.serviceURL == "https://s3.eu-central-1.amazonaws.com/")
    }

    @Test("an account keeps the endpoint, region, key and scheme of the location it came from")
    func accountFromLocation() {
        let location = S3Location(
            host: "minio.local",
            port: 9000,
            bucket: "backups",
            region: "us-east-1",
            accessKeyID: "MINIOKEY",
            addressing: .path,
            usesTLS: false
        )
        let account = location.account
        #expect(account.host == "minio.local")
        #expect(account.port == 9000)
        #expect(account.region == "us-east-1")
        #expect(account.accessKeyID == "MINIOKEY")
        #expect(account.usesTLS == false)
        // Path-style already leaves the bucket out of the host, so the only visible difference is
        // the path — which is exactly the point: one spelling for both addressing modes.
        #expect(account.serviceURL == "http://minio.local:9000/")
    }

    @Test("a default port is left out of the URL, because SigV4 signs the Host header")
    func defaultPortIsOmitted() {
        let tls = S3Account(
            host: "s3.us-east-1.amazonaws.com",
            region: "us-east-1",
            accessKeyID: "A"
        )
        #expect(tls.serviceURL == "https://s3.us-east-1.amazonaws.com/")
        let plain = S3Account(
            host: "minio.local",
            region: "us-east-1",
            accessKeyID: "A",
            usesTLS: false
        )
        #expect(plain.serviceURL == "http://minio.local/")
    }

    // MARK: - The arguments

    @Test("the bucket list is a signed GET of the endpoint root, with the credential on stdin")
    func listBucketsArguments() {
        let arguments = S3ProcessArguments.listBuckets(account: account)
        #expect(arguments.last == "https://s3.eu-central-1.amazonaws.com/")
        #expect(arguments.contains("-K"))
        #expect(arguments.contains("--aws-sigv4"))
        #expect(arguments.contains("aws:amz:eu-central-1:s3"))
        // `max-buckets` is not sent: AWS returns the whole list without it, so sending it would
        // create the pagination it looks like it manages.
        #expect(!arguments.contains { $0.contains("max-buckets") })
        // The two flags `common` argues against must not have crept in through the second spelling.
        #expect(!arguments.contains("--fail"))
        #expect(!arguments.contains("--location"))
    }

    @Test("no secret reaches argv")
    func secretStaysOffTheCommandLine() {
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let arguments = S3ProcessArguments.listBuckets(account: account, continuationToken: "t")
        #expect(!arguments.contains { $0.contains(secret) })
    }

    @Test("a continuation token is percent-encoded going back")
    func continuationTokenIsEncoded() {
        // The object listing's measured trap, applied before it can bite: an opaque base64 token
        // round-trips raw right up until one carries `+`, `/` or `=`.
        let arguments = S3ProcessArguments.listBuckets(account: account, continuationToken: "a+b/c=")
        #expect(
            arguments.last == "https://s3.eu-central-1.amazonaws.com/?continuation-token=a%2Bb%2Fc%3D"
        )
    }

    @Test("an empty token is no token at all")
    func emptyTokenIsOmitted() {
        let arguments = S3ProcessArguments.listBuckets(account: account, continuationToken: "")
        #expect(arguments.last == "https://s3.eu-central-1.amazonaws.com/")
    }

    // MARK: - The parser

    @Test("the documented response yields its buckets in order")
    func parsesTheDocumentedShape() throws {
        let list = try S3BucketListParser.parse(Self.twoBuckets)
        #expect(list.buckets.map(\.name) == ["photos", "backups"])
        #expect(list.nextContinuationToken == nil)
        let created = try #require(list.buckets.first?.creationDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(calendar.component(.year, from: created) == 2026)
        #expect(calendar.component(.month, from: created) == 1)
        #expect(calendar.component(.day, from: created) == 2)
    }

    // There was a test here asserting that the owner block's name is not read as a bucket. It
    // passed, and a negative control — matching on the element name alone, with no parent — showed
    // it passed for nothing: the owner carries `<ID>` and `<DisplayName>`, so there is no `<Name>`
    // outside `<Bucket>` to confuse. The claim it rested on is corrected on the delegate itself.
    // What genuinely holds about `<Owner>` is that it is *not required*, which `bareBucket` pins.

    @Test("a bucket with no date and no region still lists")
    func optionalFieldsAreOptional() throws {
        let list = try S3BucketListParser.parse(Self.bareBucket)
        let bucket = try #require(list.buckets.first)
        #expect(bucket.name == "minimal")
        #expect(bucket.creationDate == nil)
        #expect(bucket.region == nil)
    }

    @Test("BucketRegion is read when the server sends it")
    func readsBucketRegion() throws {
        let list = try S3BucketListParser.parse(Self.twoBuckets)
        #expect(list.buckets.map(\.region) == ["eu-central-1", nil])
    }

    @Test("an account with no buckets is an answer, not a failure")
    func emptyAccountParses() throws {
        let list = try S3BucketListParser.parse(Self.noBuckets)
        #expect(list.buckets.isEmpty)
        #expect(list.nextContinuationToken == nil)
    }

    @Test("an error document is not a bucket list")
    func errorDocumentThrows() {
        let denied = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
            """.utf8
        )
        #expect(throws: S3ListingParseError.notABucketList) {
            try S3BucketListParser.parse(denied)
        }
    }

    @Test(
        "both continuation spellings are read",
        arguments: ["ContinuationToken", "NextContinuationToken"]
    )
    func readsEitherContinuationSpelling(element: String) throws {
        // The reference gives this response `ContinuationToken` where every other paginated S3
        // response spells it `NextContinuationToken`, and with no captured bytes there is nothing
        // here to settle which a given server sends. Reading one risks a list that stops early and
        // looks complete.
        let data = Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Buckets><Bucket><Name>one</Name></Bucket></Buckets>
              <\(element)>page-2</\(element)>
            </ListAllMyBucketsResult>
            """.utf8
        )
        #expect(try S3BucketListParser.parse(data).nextContinuationToken == "page-2")
    }

    // MARK: - The page loop

    @Test("every page is walked and the pages are concatenated")
    func walksEveryPage() throws {
        var asked: [String?] = []
        let buckets = try S3BucketEnumeration.allBuckets { token in
            asked.append(token)
            switch token {
            case nil: return S3BucketList(
                    buckets: [S3Bucket(name: "a")],
                    nextContinuationToken: "t1"
                )
            case "t1": return S3BucketList(
                    buckets: [S3Bucket(name: "b")],
                    nextContinuationToken: "t2"
                )
            default: return S3BucketList(buckets: [S3Bucket(name: "c")])
            }
        }
        #expect(buckets.map(\.name) == ["a", "b", "c"])
        #expect(asked == [nil, "t1", "t2"])
    }

    @Test("a server that repeats its own token is refused rather than looped forever")
    func refusesARepeatedToken() {
        #expect(throws: S3ListingParseError.bucketListDidNotAdvance) {
            try S3BucketEnumeration.allBuckets { token in
                S3BucketList(
                    buckets: [S3Bucket(name: "a")],
                    nextContinuationToken: token == nil ? "same" : "same"
                )
            }
        }
    }

    @Test("a run past the page limit is refused rather than silently truncated")
    func refusesToRunPastThePageLimit() {
        var page = 0
        #expect(throws: S3ListingParseError.bucketListTooLong) {
            try S3BucketEnumeration.allBuckets(pageLimit: 3) { _ in
                page += 1
                return S3BucketList(
                    buckets: [S3Bucket(name: "b\(page)")],
                    nextContinuationToken: "t\(page)"
                )
            }
        }
    }

    @Test("an empty token ends the walk as surely as a missing one")
    func emptyTokenEndsTheWalk() throws {
        let buckets = try S3BucketEnumeration.allBuckets { _ in
            S3BucketList(buckets: [S3Bucket(name: "only")], nextContinuationToken: "")
        }
        #expect(buckets.map(\.name) == ["only"])
    }

    // MARK: - Fixtures

    private static let twoBuckets = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Owner><ID>c1b2a3</ID><DisplayName>someone@example.com</DisplayName></Owner>
          <Buckets>
            <Bucket>
              <Name>photos</Name>
              <CreationDate>2026-01-02T03:04:05.000Z</CreationDate>
              <BucketRegion>eu-central-1</BucketRegion>
            </Bucket>
            <Bucket>
              <Name>backups</Name>
              <CreationDate>2025-06-07T08:09:10Z</CreationDate>
            </Bucket>
          </Buckets>
        </ListAllMyBucketsResult>
        """.utf8
    )

    private static let bareBucket = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Buckets><Bucket><Name>minimal</Name></Bucket></Buckets>
        </ListAllMyBucketsResult>
        """.utf8
    )

    private static let noBuckets = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <Owner><ID>c1b2a3</ID><DisplayName>someone@example.com</DisplayName></Owner>
          <Buckets/>
        </ListAllMyBucketsResult>
        """.utf8
    )
}
