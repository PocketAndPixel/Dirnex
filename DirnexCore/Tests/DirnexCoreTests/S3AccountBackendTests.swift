import Foundation
import Testing

@testable import DirnexCore

/// A fake ``S3AccountTransport``. Pages are handed out in order so the enumeration loop can be told
/// apart from a repeated first request, the same shape `FakeS3Transport` uses for object listings.
final class FakeS3AccountTransport: S3AccountTransport, @unchecked Sendable {
    enum Call: Equatable {
        case list(continuationToken: String?)
        case create(String)
        case delete(String)
        case head(String)
    }

    /// Every call in order — the order is what several of these tests are about (a create that
    /// never checked first would show exactly one call).
    var calls: [Call] = []

    var listPages: [S3Response] = []
    var createResponse = S3Response(status: 200)
    var deleteResponse = S3Response(status: 204)
    var headResponse = S3Response(status: 404)
    var thrownError: S3ResponseError?

    private var listIndex = 0

    func listBuckets(continuationToken: String?) throws -> S3Response {
        calls.append(.list(continuationToken: continuationToken))
        if let thrownError { throw thrownError }
        guard !listPages.isEmpty else { return S3Response(status: 200) }
        let page = listPages[min(listIndex, listPages.count - 1)]
        listIndex += 1
        return page
    }

    func createBucket(name: String) throws -> S3Response {
        calls.append(.create(name))
        if let thrownError { throw thrownError }
        return createResponse
    }

    func deleteBucket(name: String) throws -> S3Response {
        calls.append(.delete(name))
        if let thrownError { throw thrownError }
        return deleteResponse
    }

    func headBucket(name: String) throws -> S3Response {
        calls.append(.head(name))
        if let thrownError { throw thrownError }
        return headResponse
    }
}

/// The account backend — one S3 account browsed as a flat directory of buckets (PLAN.md §M21).
///
/// The fixtures below are the bytes a **real** S3-compatible endpoint sent on 2026-08-13, not
/// documentation: no `<BucketRegion>` element, an `<Owner>` carrying an empty `<DisplayName>`, and
/// a fractional-second creation stamp. Slice 7's parser suite was built from the API reference and
/// said so; this is the first time these bytes have been in the suite.
@Suite("S3 account backend")
struct S3AccountBackendTests {
    private static let account = S3Account(
        host: "s3.lax.sharktech.net",
        region: "us-east-1",
        accessKeyID: "AKIAEXAMPLE",
        addressing: .path
    )

    private static let realBucketList = Data("""
    <?xml version="1.0" encoding="UTF-8"?>\
    <ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
    <Owner><ID>da0b957a94e834f5</ID><DisplayName></DisplayName></Owner>\
    <Buckets>\
    <Bucket><Name>dirnex-probe-a</Name><CreationDate>2026-08-13T13:58:42.000Z</CreationDate></Bucket>\
    <Bucket><Name>dirnex-test</Name><CreationDate>2026-08-13T12:00:27.000Z</CreationDate></Bucket>\
    </Buckets></ListAllMyBucketsResult>
    """.utf8)

    private static func errorBody(_ code: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?><Error><Code>\(code)</Code>\
        <Message>whatever the server says</Message></Error>
        """.utf8)
    }

    private func backend(
        _ transport: FakeS3AccountTransport
    ) -> S3AccountBackend {
        S3AccountBackend(account: Self.account, transport: transport)
    }

    private var root: VFSPath { VFSPath(backend: .s3Account(Self.account), path: "/") }

    private func path(_ bucket: String) -> VFSPath {
        VFSPath(backend: .s3Account(Self.account), path: "/\(bucket)")
    }

    // MARK: - Listing

    @Test("lists an account's buckets as directories")
    func listsBucketsAsDirectories() throws {
        let transport = FakeS3AccountTransport()
        transport.listPages = [S3Response(status: 200, body: Self.realBucketList)]

        let entries = try backend(transport).listDirectory(at: root)

        #expect(entries.map(\.name) == ["dirnex-probe-a", "dirnex-test"])
        let allDirectories = entries.allSatisfy { $0.kind == .directory }
        #expect(allDirectories)
        #expect(entries.map(\.path.path) == ["/dirnex-probe-a", "/dirnex-test"])
    }

    /// A bucket has a creation date and no modification date. The Date column draws
    /// `FileEntry.unknownDate` as a dash rather than as the `01.01.1` a raw sentinel rendered
    /// before Slice 3 named it, so a bucket that *does* carry a date must not fall back to it.
    @Test("a bucket's creation date is carried onto the row")
    func carriesTheCreationDate() throws {
        let transport = FakeS3AccountTransport()
        transport.listPages = [S3Response(status: 200, body: Self.realBucketList)]

        let entries = try backend(transport).listDirectory(at: root)
        let first = try #require(entries.first)

        #expect(first.creationDate != FileEntry.unknownDate)
        #expect(first.byteSize == 0)
    }

    @Test("only the root lists — a bucket is entered by connecting to it, not listed here")
    func onlyTheRootLists() {
        let transport = FakeS3AccountTransport()
        transport.listPages = [S3Response(status: 200, body: Self.realBucketList)]

        #expect(throws: VFSError.notFound(path("dirnex-test"))) {
            try backend(transport).listDirectory(at: path("dirnex-test"))
        }
    }

    @Test("a path from another connection is refused before it reaches the wire")
    func refusesAPathFromAnotherConnection() {
        let transport = FakeS3AccountTransport()
        let foreign = VFSPath(backend: .local, path: "/tmp")

        #expect(throws: (any Error).self) {
            try backend(transport).listDirectory(at: foreign)
        }
        #expect(transport.calls.isEmpty)
    }

    // MARK: - Creating

    /// The measurement this guard exists for: a real endpoint answers **200** to a `CreateBucket`
    /// on a name it already holds, silently changing nothing. Without the check, F7 on a taken name
    /// reports success.
    @Test("refuses to create a bucket that already exists, which the server would not")
    func refusesToCreateAnExistingBucket() {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 200)
        transport.listPages = [S3Response(status: 200, body: Self.realBucketList)]
        transport.createResponse = S3Response(status: 200) // what the real server answers

        #expect(throws: VFSError.alreadyExists(path("dirnex-test"))) {
            try backend(transport).createDirectory(at: path("dirnex-test"))
        }
        // And it never asked the server to create anything. The listing is the second half of the
        // refusal, not a third opinion: the head raises the question and it answers it.
        #expect(transport.calls == [.head("dirnex-test"), .list(continuationToken: nil)])
    }

    /// **`HeadBucket` lies about a bucket this account has just deleted, so it cannot be the whole
    /// of the guard above.** Measured 2026-08-20 on real AWS, polling straight after a `DELETE`
    /// returned 204: `404 404 200 200 200 200 200 200 404 200 404 404`, while `ListAllMyBuckets`
    /// read the name as absent 12 times out of 12. Reported by a user as F7 answering "already
    /// exists" for a bucket the pane was quite correctly not drawing — and only sometimes, which is
    /// what kept it from looking like a rule.
    ///
    /// The listing is what the pane draws, so resting the refusal on it is also what stops the two
    /// from ever contradicting each other.
    @Test("a stale head does not refuse a name the listing does not have")
    func createsWhenOnlyTheHeadThinksItExists() throws {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 200) // the phantom
        transport.listPages = [S3Response(status: 200, body: Self.realBucketList)]

        try backend(transport).createDirectory(at: path("dirnex-probe-a-gone"))

        #expect(transport.calls == [
            .head("dirnex-probe-a-gone"),
            .list(continuationToken: nil),
            .create("dirnex-probe-a-gone")
        ])
    }

    /// A listing that cannot be had is not evidence the name is free, and the two failure
    /// directions are not equal: refusing wrongly is recoverable, while sending a create at a
    /// service that answers 200 and does nothing reports work that never happened.
    @Test("a listing that fails leaves the head its old authority")
    func refusesWhenTheListingCannotBeAsked() {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 200)
        transport.listPages = [S3Response(status: 403, body: Self.errorBody("AccessDenied"))]

        #expect(throws: VFSError.alreadyExists(path("dirnex-test"))) {
            try backend(transport).createDirectory(at: path("dirnex-test"))
        }
        #expect(!transport.calls.contains(.create("dirnex-test")))
    }

    @Test("creates a bucket that is not there")
    func createsANewBucket() throws {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 404, body: Self.errorBody("NoSuchBucket"))

        try backend(transport).createDirectory(at: path("dirnex-probe-a"))

        #expect(transport.calls == [.head("dirnex-probe-a"), .create("dirnex-probe-a")])
    }

    /// The local refusal, and the reason it is local: the server answers every broken rule with one
    /// indistinguishable `400 InvalidBucketName`.
    @Test("an invalid name is refused without a request")
    func refusesAnInvalidNameLocally() {
        let transport = FakeS3AccountTransport()

        #expect(throws: VFSError.unsupported(.bucketNameNotValid(name: "Bad_Name"))) {
            try backend(transport).createDirectory(at: path("Bad_Name"))
        }
        #expect(transport.calls.isEmpty)
    }

    // MARK: - Deleting

    /// A 409 maps to `alreadyExists` through the shared classifier, which answers a *delete* with
    /// "this already exists". `BucketNotEmpty` therefore gets its own sentence.
    @Test("a non-empty bucket is refused by name, not as “already exists”")
    func refusesANonEmptyBucketByName() {
        let transport = FakeS3AccountTransport()
        transport.deleteResponse = S3Response(status: 409, body: Self.errorBody("BucketNotEmpty"))

        #expect(throws: VFSError.unsupported(.bucketNotEmpty(name: "dirnex-test"))) {
            try backend(transport).removeItem(at: path("dirnex-test"))
        }
    }

    /// Success is 204 here. A classifier keyed on `== 200` would read every successful delete as a
    /// failure — the trap a resumed download's 206 set, arriving on another verb.
    @Test("a 204 is success, not a failure")
    func treatsA204AsSuccess() throws {
        let transport = FakeS3AccountTransport()
        transport.deleteResponse = S3Response(status: 204)

        try backend(transport).removeItem(at: path("dirnex-probe-a"))

        #expect(transport.calls == [.delete("dirnex-probe-a")])
    }

    @Test("a missing bucket is not found")
    func reportsAMissingBucket() {
        let transport = FakeS3AccountTransport()
        transport.deleteResponse = S3Response(status: 404, body: Self.errorBody("NoSuchBucket"))

        #expect(throws: VFSError.notFound(path("never-existed"))) {
            try backend(transport).removeItem(at: path("never-existed"))
        }
    }

    @Test("the account root itself cannot be deleted")
    func refusesToDeleteTheAccountRoot() {
        let transport = FakeS3AccountTransport()

        #expect(throws: VFSError.unsupported(.deleteConnectionRoot)) {
            try backend(transport).removeItem(at: root)
        }
        #expect(transport.calls.isEmpty)
    }

    // MARK: - What a bucket is not

    /// S3 has no rename at any level, so this refuses by name rather than being faked as a copy —
    /// which for a bucket would mean re-uploading everything in it.
    @Test("a bucket cannot be renamed")
    func refusesToRenameABucket() {
        let transport = FakeS3AccountTransport()

        #expect(throws: VFSError.unsupported(.moveItem)) {
            try backend(transport).moveItem(at: path("a"), to: path("b"))
        }
        #expect(transport.calls.isEmpty)
    }

    @Test("no rename capability, so F2 is never offered on a bucket")
    func advertisesNoRename() {
        let transport = FakeS3AccountTransport()
        let capabilities = backend(transport).capabilities

        #expect(capabilities.contains(.read))
        #expect(capabilities.contains(.write))
        #expect(!capabilities.contains(.rename))
        #expect(!capabilities.contains(.trash))
        #expect(!capabilities.contains(.watch))
    }

    // MARK: - Region

    @Test("a bucket's region is read when the server names one")
    func readsTheBucketRegion() throws {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 200, bucketRegion: "eu-west-1")

        #expect(try backend(transport).region(ofBucketNamed: "somewhere") == "eu-west-1")
    }

    /// `nil` is an ordinary answer, measured: a real S3-compatible endpoint sends the header on no
    /// response at all. The caller keeps the account's own region.
    @Test("no region header is an answer, not a failure")
    func absentRegionHeaderIsAnAnswer() throws {
        let transport = FakeS3AccountTransport()
        transport.headResponse = S3Response(status: 200, bucketRegion: nil)

        #expect(try backend(transport).region(ofBucketNamed: "somewhere") == nil)
    }
}
