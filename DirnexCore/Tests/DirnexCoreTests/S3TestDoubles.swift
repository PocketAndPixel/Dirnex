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

    struct Upload: Equatable {
        let localPath: String
        let key: String
    }

    struct Copy: Equatable {
        let sourceKey: String
        let destinationKey: String
    }

    /// Every write the backend made, in order — one list rather than several, because the *order*
    /// is what several of these tests are about: a rename that deleted before it copied, or a
    /// folder delete that removed the marker before its contents, would pass a per-verb tally.
    struct PartUpload: Equatable {
        let localPath: String
        let key: String
        let uploadID: String
        let partNumber: Int
    }

    enum Write: Equatable {
        case upload(Upload)
        case putEmpty(String)
        case copy(Copy)
        case delete(String)
        case deleteBatch([String])
        case createMultipart(String)
        case uploadPart(PartUpload)
        case completeMultipart(key: String, uploadID: String, parts: [S3UploadedPart])
        case abortMultipart(key: String, uploadID: String)
    }

    /// Handed out in order, one per `listObjects` call. The last one repeats once exhausted, so a
    /// test that means to exercise a bounded loop cannot accidentally run out of fixtures.
    var listPages: [S3Response] = []
    var headResponse = S3Response(status: 404)
    var downloadResponse = S3Response(status: 200)
    /// The answer every write verb gives, unless a batch answer is queued below.
    var writeResponse = S3Response(status: 200)
    /// Handed out in order, one per `deleteObjects` call, so a partial-failure body can be aimed at
    /// a particular batch. Falls back to ``writeResponse`` once exhausted.
    var deleteBatchResponses: [S3Response] = []
    /// Thrown by every verb when set — the "the request never reached a server" half.
    var thrownError: S3ResponseError?

    /// The answer to `CreateMultipartUpload`. A real `InitiateMultipartUploadResult` by default, so
    /// a test only overrides it when the *opening* is what it is about.
    var createMultipartResponse = S3Response.ok(S3Fixtures.initiateMultipart)
    /// Handed out in order, one per part. Falls back to a 200 carrying a synthetic ETag once
    /// exhausted, so a test aiming a failure at part 3 says only that.
    var uploadPartResponses: [S3Response] = []
    var completeMultipartResponse = S3Response.ok(S3Fixtures.completeMultipart)
    /// Set to make the abort itself fail, which must never replace the error that provoked it.
    var abortThrows = false

    private(set) var listRequests: [ListRequest] = []
    private(set) var downloads: [Download] = []
    /// Transfers this fake was asked to abandon — the record that makes the cancellation rule
    /// assertable at all. A real transport polls `isCancelled` *while the bytes move*, which a
    /// headless double cannot reproduce; what it can pin is that the backend hands the flag down to
    /// the transfer verb instead of only checking it at the file boundary, which is exactly the gap
    /// measured 2026-08-14 (docs/NOTES.md ▸ curl for S3).
    private(set) var cancelledTransfers: [String] = []
    private(set) var headKeys: [String] = []
    private(set) var writes: [Write] = []

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

    func download(
        key: String,
        to localPath: String,
        resume: Bool,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        // A real transport polls this *while the bytes move*; a fake can only record that it was
        // offered the chance, which is the half a headless test can pin.
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        downloads.append(Download(key: key, localPath: localPath, resume: resume))
        return downloadResponse
    }

    func head(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        headKeys.append(key)
        return headResponse
    }

    // MARK: - Writes

    func upload(
        localPath: String,
        to key: String,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        writes.append(.upload(Upload(localPath: localPath, key: key)))
        return writeResponse
    }

    func putEmptyObject(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.putEmpty(key))
        return writeResponse
    }

    func copyObject(from sourceKey: String, to destinationKey: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.copy(Copy(sourceKey: sourceKey, destinationKey: destinationKey)))
        return writeResponse
    }

    func deleteObject(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.delete(key))
        return writeResponse
    }

    func deleteObjects(keys: [String]) throws -> S3Response {
        if let thrownError { throw thrownError }
        let batchIndex = writes.filter {
            if case .deleteBatch = $0 { return true }
            return false
        }.count
        writes.append(.deleteBatch(keys))
        guard batchIndex < deleteBatchResponses.count else { return writeResponse }
        return deleteBatchResponses[batchIndex]
    }

    // MARK: - Multipart

    func createMultipartUpload(key: String) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.createMultipart(key))
        return createMultipartResponse
    }

    func uploadPart(
        localPath: String,
        to key: String,
        uploadID: String,
        partNumber: Int,
        isCancelled: () -> Bool
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        if isCancelled() { cancelledTransfers.append(key); throw CancellationError() }
        // Recorded before the response is chosen, so a test can assert on the slice file the
        // backend actually produced — including that it existed at the moment of the call.
        sliceSizes.append(sizeOfFile(localPath))
        let index = partNumber - 1
        writes.append(
            .uploadPart(
                PartUpload(
                    localPath: localPath,
                    key: key,
                    uploadID: uploadID,
                    partNumber: partNumber
                )
            )
        )
        guard index < uploadPartResponses.count else {
            return S3Response(status: 200, etag: "\"etag-part-\(partNumber)\"")
        }
        return uploadPartResponses[index]
    }

    func completeMultipartUpload(
        key: String,
        uploadID: String,
        parts: [S3UploadedPart]
    ) throws -> S3Response {
        if let thrownError { throw thrownError }
        writes.append(.completeMultipart(key: key, uploadID: uploadID, parts: parts))
        return completeMultipartResponse
    }

    func abortMultipartUpload(key: String, uploadID: String) throws -> S3Response {
        writes.append(.abortMultipart(key: key, uploadID: uploadID))
        if abortThrows { throw S3ResponseError.transport(.other) }
        return S3Response(status: 204)
    }

    /// The size of each slice at the moment its part was uploaded — how a test proves the backend
    /// cut the ranges the plan describes without reaching into the temp directory afterwards, by
    /// which time the slice is (correctly) gone.
    private(set) var sliceSizes: [Int64] = []

    private func sizeOfFile(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) as? Int64 ?? -1
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
}
