import Foundation

@testable import DirnexCore

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

    /// A recursive enumeration (`delimiter=nil`) of a folder holding two files **and its own
    /// marker**, which is the shape a batch delete has to sweep: the marker is an ordinary
    /// `Contents` row, so an empty folder and a full one take the same path.
    static let recursivePage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix>docs/</Prefix><KeyCount>3</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>docs/</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/a.txt</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>12</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/sub/b.txt</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254767&quot;</ETag><Size>34</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// A recursive enumeration of the **bucket root**, which is what a search takes: five keys
    /// spanning three depths, two of them directory markers.
    ///
    /// Note there is not one `<CommonPrefixes>` element in it. That is the whole reason the flat
    /// route has to synthesize folders — `docs` and `sub` appear in this document only as parts of
    /// other objects' keys, and `empty/` exists **only** as its own marker, which is the sole trace
    /// an empty folder leaves in a flat store.
    static let subtreeRootPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix></Prefix><KeyCount>5</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>CHANGELOG</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>257098</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/report.pdf</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254768&quot;</ETag><Size>4096</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/sub/notes.txt</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254769&quot;</ETag><Size>34</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>empty/</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// The first page of a two-page flat enumeration: the **deepest** key on its own, so what the
    /// second page proves is that the folders synthesized here are not emitted again — and that a
    /// row from page one still sorts by its depth rather than by the page it arrived on.
    static let subtreeFirstPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix></Prefix><NextContinuationToken>1PS1Je8Je9+fEnmTJ94R3S298dc9ST1JnbEKoQSuyxjjBs2R4yx2\
    EmIDBiSbDfoKfHFUVn+f1Eg8=</NextContinuationToken><KeyCount>1</KeyCount><MaxKeys>1</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>true</IsTruncated>\
    <Contents><Key>docs/sub/notes.txt</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254769&quot;</ETag><Size>34</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// The rest of that enumeration — the four keys ``subtreeFirstPage`` did not carry, one of them
    /// under a folder that page already named.
    static let subtreeSecondPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix></Prefix><KeyCount>4</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>CHANGELOG</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254766&quot;</ETag><Size>257098</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>docs/report.pdf</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;6d1792d429159aabb630926c37254768&quot;</ETag><Size>4096</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>empty/</Key><LastModified>2015-09-08T15:01:44.000Z</LastModified>\
    <ETag>&quot;d41d8cd98f00b204e9800998ecf8427e&quot;</ETag><Size>0</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    /// `prefix=docs` answered as a folder — the `CommonPrefixes` row a stat reads.
    static let statDocsFolder = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>1000genomes</Name>\
    <Prefix>docs</Prefix><KeyCount>1</KeyCount><MaxKeys>1000</MaxKeys><Delimiter>/</Delimiter>\
    <IsTruncated>false</IsTruncated><CommonPrefixes><Prefix>docs/</Prefix></CommonPrefixes>\
    </ListBucketResult>
    """

    /// A `DeleteResult` that succeeded quietly — what `<Quiet>true</Quiet>` produces.
    static let deleteQuiet = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></DeleteResult>
    """

    /// A **200** carrying a per-key refusal — the case that makes the body the outcome rather than
    /// the status, and the one a status-only reader would report as a successful delete.
    static let deletePartialFailure = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
    <Deleted><Key>docs/a.txt</Key></Deleted>\
    <Error><Key>docs/sub/b.txt</Key><Code>AccessDenied</Code>\
    <Message>Access Denied</Message></Error></DeleteResult>
    """

    /// The answer to `CreateMultipartUpload` — the id every later request quotes.
    static let initiateMultipart = """
    <?xml version="1.0" encoding="UTF-8"?>
    <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
    <Bucket>1000genomes</Bucket><Key>big.bin</Key>\
    <UploadId>2~mZ8kR9tPq/LxV+3nD4bW5cYgH1jF6sA=</UploadId></InitiateMultipartUploadResult>
    """

    /// The upload id `initiateMultipart` carries, verbatim — deliberately holding `/`, `+` and `=`,
    /// the three characters that make an opaque token need query encoding on the way back.
    static let initiateUploadID = "2~mZ8kR9tPq/LxV+3nD4bW5cYgH1jF6sA="

    /// A completion that really completed.
    static let completeMultipart = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
    <Location>https://1000genomes.s3.us-east-1.amazonaws.com/big.bin</Location>\
    <Bucket>1000genomes</Bucket><Key>big.bin</Key>\
    <ETag>&quot;d972596d0b33e62664c950f532f9b3f1-3&quot;</ETag></CompleteMultipartUploadResult>
    """

    /// A completion that **failed inside a 200** — the shape a status-only reader calls a success
    /// while the object does not exist.
    static let completeMultipartFailed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.\
    </Message><RequestId>656c76696e6727</RequestId><HostId>Uuag1LuByRx9e6j5</HostId></Error>
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
    s3-up=0

    """

    /// `curl`'s stderr for a successful upload: nothing came down, the file went up.
    static let uploadStderr = """
    s3-status=200
    s3-region=
    s3-length=0
    s3-size=0
    s3-up=3145728

    """

    /// A **refused** upload, which is the reason the two counters cannot be one number: the whole
    /// file went out and the `<Error>` document came back, so both are non-zero in one invocation.
    static let refusedUploadStderr = """
    s3-status=403
    s3-region=
    s3-length=153
    s3-size=153
    s3-up=3145728

    """

    /// `amzn-s3-df` in `eu-north-1`, `prefix=dirnex-live-probe/slice10/&encoding-type=url`,
    /// captured 2026-08-18 — three keys written for this fixture and deleted after it.
    ///
    /// The whole point of it is what `encoding-type=url` does to a **space**. The same three keys
    /// listed again with the parameter left off came back as `a+b.txt`, `c d.txt` and `trailing `,
    /// so the encoding here is `application/x-www-form-urlencoded`: a space is `+` and a literal
    /// plus is `%2B`. No public bucket can stand in — the ones the fixtures above came from have no
    /// spaces in any key, and the S3-compatible endpoint the whitespace suite uses ignores the
    /// parameter and never echoes it.
    static let formEncodedPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>amzn-s3-df</Name>\
    <Prefix>dirnex-live-probe/slice10/</Prefix><KeyCount>3</KeyCount><MaxKeys>1000</MaxKeys>\
    <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
    <Contents><Key>dirnex-live-probe/slice10/a%2Bb.txt</Key>\
    <LastModified>2026-08-18T14:12:40.000Z</LastModified>\
    <ETag>&quot;9dd4e461268c8034f5c8564e155c67a6&quot;</ETag><Size>1</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>dirnex-live-probe/slice10/c+d.txt</Key>\
    <LastModified>2026-08-18T14:12:40.000Z</LastModified>\
    <ETag>&quot;9dd4e461268c8034f5c8564e155c67a6&quot;</ETag><Size>1</Size>\
    <StorageClass>STANDARD</StorageClass></Contents>\
    <Contents><Key>dirnex-live-probe/slice10/trailing+</Key>\
    <LastModified>2026-08-18T14:12:40.000Z</LastModified>\
    <ETag>&quot;9dd4e461268c8034f5c8564e155c67a6&quot;</ETag><Size>1</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """
}
