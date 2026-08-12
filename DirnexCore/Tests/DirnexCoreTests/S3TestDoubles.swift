import Foundation

@testable import DirnexCore

/// A fake ``S3Transport``, fed the bytes real buckets sent.
///
/// It hands out queued list responses in order, which is what makes the pagination loop testable:
/// the loop's job is to ask again with the token it was given, and a queue is the only double that
/// can tell a correct second request from a repeated first one.
final class FakeS3Transport: S3Transport, @unchecked Sendable {
    struct ListRequest: Equatable {
        let prefix: String
        let delimiter: String?
        let continuationToken: String?
    }

    struct Download: Equatable {
        let key: String
        let localPath: String
        let resume: Bool
    }

    /// Handed out in order, one per `listObjects` call. The last one repeats once exhausted, so a
    /// test that means to exercise a bounded loop cannot accidentally run out of fixtures.
    var listPages: [S3Response] = []
    var headResponse = S3Response(status: 404)
    var downloadResponse = S3Response(status: 200)
    /// Thrown by every verb when set — the "the request never reached a server" half.
    var thrownError: S3ResponseError?

    private(set) var listRequests: [ListRequest] = []
    private(set) var downloads: [Download] = []
    private(set) var headKeys: [String] = []

    func listObjects(
        prefix: String,
        delimiter: String?,
        continuationToken: String?
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        listRequests.append(
            ListRequest(prefix: prefix, delimiter: delimiter, continuationToken: continuationToken)
        )
        guard !listPages.isEmpty else { return S3Response(status: 200) }
        let index = min(listRequests.count - 1, listPages.count - 1)
        return listPages[index]
    }

    func download(key: String, to localPath: String, resume: Bool) throws -> S3Response {
        if let thrownError { throw thrownError }
        downloads.append(Download(key: key, localPath: localPath, resume: resume))
        return downloadResponse
    }

    func head(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        headKeys.append(key)
        return headResponse
    }
}

extension S3Response {
    /// A 200 carrying `xml`.
    static func ok(_ xml: String) -> S3Response {
        S3Response(status: 200, body: Data(xml.utf8))
    }
}

/// Bytes captured from real buckets on 2026-08-12 — `1000genomes` and `nasa-nex`, both public and
/// anonymously readable. Written from a live response rather than from the documentation for the
/// reason docs/NOTES.md gives about corpora: a hand-written fixture only proves the parser agrees
/// with whoever wrote it, and the two facts these pin (whole keys at every depth, and a prefix
/// matching siblings) are exactly the ones a from-the-docs fixture would spell away.
enum S3Fixtures {
    /// `1000genomes`, root, `max-keys=2` — one file, one folder, and a continuation token carrying
    /// `+`, `/` and `=`, which is the case that makes query encoding load-bearing.
    static let rootPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix></Prefix><NextContinuationToken>1PS1Je8Je9+fEnmTJ94R3S298dc9ST1JnbEKoQSuyxjjBs2R4yx2\
    EmIDBiSbDfoKfHFUVn+f1Eg8=</NextContinuationToken><KeyCount>2</KeyCount><MaxKeys>2</MaxKeys>\
    <Delimiter>/</Delimiter><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>\
    <Contents><Key>20131219.populations.tsv</Key><LastModified>2015-09-08T21:16:09.000Z\
    </LastModified><ETag>&quot;fa5e051926444a81f35eb807cb6f63fd&quot;</ETag><Size>1663</Size>\
    <StorageClass>STANDARD</StorageClass></Contents><CommonPrefixes>\
    <Prefix>1000G_2504_high_coverage/</Prefix></CommonPrefixes></ListBucketResult>
    """

    /// The token `rootPage` hands back, verbatim.
    static let rootPageToken =
        "1PS1Je8Je9+fEnmTJ94R3S298dc9ST1JnbEKoQSuyxjjBs2R4yx2EmIDBiSbDfoKfHFUVn+f1Eg8="

    /// The last page of the same listing: no token, not truncated.
    static let finalPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix></Prefix><KeyCount>1</KeyCount><MaxKeys>2</MaxKeys><Delimiter>/</Delimiter>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated><Contents>\
    <Key>CHANGELOG</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>257098</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// `prefix=CHANGELOG` — the exact object, which is how a file is stat'ed in one request.
    static let statFile = finalPage

    /// `prefix=README` — **four different objects and no `README`**. The page that proves a stat
    /// must match exactly: taking the first row here reports `README.alignment_data`'s 15 977
    /// bytes under the name `README`.
    static let statAmbiguous = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix>README</Prefix><NextContinuationToken>1fICyM2XSSRqS9+DkL8wtP0Oo/77hvTKeZ/XNzb1y71RP\
    QPGPsF/k/Q==</NextContinuationToken><KeyCount>3</KeyCount><MaxKeys>3</MaxKeys>\
    <Delimiter>/</Delimiter><EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>\
    <Contents><Key>README.alignment_data</Key><LastModified>2014-09-02T15:39:53.000Z\
    </LastModified><ETag>&quot;9a74187431e1938b490efa34c2f2272d&quot;</ETag><Size>15977</Size>\
    <StorageClass>STANDARD</StorageClass></Contents><Contents><Key>README.analysis_history</Key>\
    <LastModified>2014-01-30T11:13:29.000Z</LastModified>\
    <ETag>&quot;30133df930a45b2aac29cd229169dab7&quot;</ETag><Size>5289</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// `nasa-nex`, `prefix=LOCA` — how a *folder* answers a stat: one `CommonPrefixes` row, no
    /// `Contents` at all.
    static let statFolder = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>nasa-nex</Name>\
    <Prefix>LOCA</Prefix><KeyCount>1</KeyCount><MaxKeys>20</MaxKeys><Delimiter>/</Delimiter>\
    <IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>LOCA/</Prefix></CommonPrefixes>\
    </ListBucketResult>
    """

    /// A path that is simply not there: a well-formed page with nothing in it.
    static let statMissing = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>nasa-nex</Name>\
    <Prefix>LOCA/masks</Prefix><KeyCount>0</KeyCount><MaxKeys>10</MaxKeys>\
    <Delimiter>/</Delimiter><IsTruncated>false</IsTruncated></ListBucketResult>
    """

    /// The 301 a wrong region answers with — note the endpoint is bucket-prefixed and spelled with
    /// a **dash** (`s3-us-west-2`), which is not the form this project ever builds.
    static let wrongRegion = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>PermanentRedirect</Code><Message>The bucket you are attempting to access must be \
    addressed using the specified endpoint. Please send all future requests to this endpoint.\
    </Message><Endpoint>nasa-nex.s3-us-west-2.amazonaws.com</Endpoint><Bucket>nasa-nex</Bucket>\
    <RequestId>TY8GSYETAC6D68PX</RequestId><HostId>ig/ZOr7Zvzbt</HostId></Error>
    """

    /// A bad access key id, which is a **403** — the status a bucket policy refusal also uses.
    static let invalidAccessKey = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>InvalidAccessKeyId</Code><Message>The AWS Access Key Id you provided does not \
    exist in our records.</Message><AWSAccessKeyId>AKIAIOSFODNN7EXAMPLE</AWSAccessKeyId>\
    <RequestId>BJ28272AE9ZPVRMF</RequestId><HostId>SiTuTP6H9RVunH8D</HostId></Error>
    """

    /// `curl`'s stderr for an unresolvable host, verbatim: its own prose, then the write-out.
    static let failureStderr = """
    curl: (6) Could not resolve host: no-such-host-dirnex-probe.invalid
    s3-status=000
    s3-region=
    s3-length=
    s3-size=0

    """

    /// `curl`'s stderr for a successful listing.
    static let successStderr = """
    s3-status=200
    s3-region=us-west-2
    s3-length=451
    s3-size=451

    """
}
