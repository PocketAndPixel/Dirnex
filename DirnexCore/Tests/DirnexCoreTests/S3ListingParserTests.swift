import Foundation
import Testing

@testable import DirnexCore

/// Parsing `ListObjectsV2` responses.
///
/// Every fixture below is **real AWS output**, captured 2026-08-12 by anonymously listing the
/// public `sentinel-s2-l1c` bucket. That matters for the same reason NOTES.md gives for scoring the
/// Markdown slug rule against real documents: a fixture written from the documentation proves the
/// parser agrees with whoever wrote the fixture, and the two facts that actually bite here — whole
/// keys at every depth, and `<Contents>` carrying no `<Owner>` — are both invisible that way.
@Suite("S3ListingParser")
struct S3ListingParserTests {
    /// A listing of `prefix=tiles/1/` — folders only, and truncated, so it also carries a token.
    static let foldersPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>sentinel-s2-l1c\
    </Name><Prefix>tiles/1/</Prefix><NextContinuationToken>\
    1TE8yNtjy7E8FgBWoupQkx7StbcoO2PcdzJfwpQKUUvTcmd85B6Smig==</NextContinuationToken>\
    <KeyCount>2</KeyCount><MaxKeys>2</MaxKeys><Delimiter>/</Delimiter><IsTruncated>true\
    </IsTruncated><CommonPrefixes><Prefix>tiles/1/C/</Prefix></CommonPrefixes>\
    <CommonPrefixes><Prefix>tiles/1/D/</Prefix></CommonPrefixes></ListBucketResult>
    """

    /// A listing at the bucket root carrying one real object.
    static let filesPage = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>sentinel-s2-l1c\
    </Name><Prefix></Prefix><KeyCount>1</KeyCount><MaxKeys>1000</MaxKeys><Delimiter>/</Delimiter>\
    <IsTruncated>false</IsTruncated><Contents><Key>GENERAL_QUALITY.xml</Key>\
    <LastModified>2017-04-14T14:11:15.000Z</LastModified>\
    <ETag>&quot;d7acdb4ab69421f18ae39031a6c226c9&quot;</ETag><Size>3194</Size>\
    <StorageClass>STANDARD</StorageClass></Contents></ListBucketResult>
    """

    private static func page(_ xml: String) throws -> S3ListingPage {
        try S3ListingParser.parse(Data(xml.utf8))
    }

    // MARK: - The page itself

    @Test("common prefixes are the folder rows")
    func readsCommonPrefixes() throws {
        let page = try Self.page(Self.foldersPage)
        #expect(page.commonPrefixes == ["tiles/1/C/", "tiles/1/D/"])
        #expect(page.objects.isEmpty)
    }

    @Test("a truncated page carries the token the next one must be asked for with")
    func readsContinuationToken() throws {
        let page = try Self.page(Self.foldersPage)
        #expect(page.isTruncated)
        #expect(
            page.nextContinuationToken == "1TE8yNtjy7E8FgBWoupQkx7StbcoO2PcdzJfwpQKUUvTcmd85B6Smig=="
        )
    }

    @Test("the last page has no token")
    func lastPageHasNoToken() throws {
        let page = try Self.page(Self.filesPage)
        #expect(!page.isTruncated)
        #expect(page.nextContinuationToken == nil)
    }

    @Test("an object's size and date are read, and its ETag entities are decoded")
    func readsObject() throws {
        let page = try Self.page(Self.filesPage)
        let object = try #require(page.objects.first)
        #expect(object.key == "GENERAL_QUALITY.xml")
        #expect(object.size == 3194)
        // 2017-04-14T14:11:15Z
        #expect(object.lastModified == Date(timeIntervalSince1970: 1_492_179_075))
        // Quotes and all: they are part of the value AWS sends (as `&quot;` entities, which is
        // what makes this fixture worth having), and the tag is only ever compared against another
        // reading of the same object — so tidying them off is the edit that makes two readings
        // disagree. Asserted here because the tag is what `RemoteFileRevision` upgrades a save's
        // conflict check with (PLAN.md §M21 Slice 10).
        #expect(object.entityTag == "\"d7acdb4ab69421f18ae39031a6c226c9\"")
    }

    /// A multipart upload's tag is a digest-of-digests with a part count on the end. Nothing here
    /// reads it, which is the point — it is opaque, and the parser must not develop an opinion.
    @Test("a multipart ETag is carried whole, part count and all")
    func readsMultipartETag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <KeyCount>1</KeyCount><IsTruncated>false</IsTruncated><Contents><Key>big.iso</Key>\
        <LastModified>2026-08-13T10:00:00.000Z</LastModified>\
        <ETag>&quot;9b2cf535f27731c974343645a3985328-4&quot;</ETag><Size>41943040</Size>\
        </Contents></ListBucketResult>
        """
        let object = try #require(Self.page(xml).objects.first)

        #expect(object.entityTag == "\"9b2cf535f27731c974343645a3985328-4\"")
    }

    /// Not every S3-compatible server sends one, and a listing without it is still a listing — the
    /// same rule `lastModified` follows. Two things are pinned at once, and the second is the one
    /// that bites: a tag must be `nil` rather than `""` (so "no tag" cannot compare equal to
    /// another object's "no tag" and be read as proof that neither has changed), and a row that
    /// carries none must not **inherit** its predecessor's — the accumulator is reused per
    /// `<Contents>`, which is exactly how one refused key became a batch of them in
    /// `S3DeleteBatch`'s parser (docs/NOTES.md ▸ curl for S3).
    @Test("a row with no ETag carries none, and does not inherit the row above it")
    func objectWithoutETag() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <KeyCount>3</KeyCount><IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key>\
        <LastModified>2026-08-13T10:00:00.000Z</LastModified>\
        <ETag>&quot;aaa&quot;</ETag><Size>1</Size></Contents><Contents><Key>b.txt</Key>\
        <LastModified>2026-08-13T10:00:00.000Z</LastModified><Size>2</Size></Contents>\
        <Contents><Key>c.txt</Key><LastModified>2026-08-13T10:00:00.000Z</LastModified>\
        <ETag></ETag><Size>3</Size></Contents></ListBucketResult>
        """
        let objects = try Self.page(xml).objects

        #expect(objects.map(\.entityTag) == ["\"aaa\"", nil, nil])
    }

    @Test("a top-level Prefix echo is not mistaken for a common prefix")
    func topLevelPrefixIsNotAFolder() throws {
        // `<Prefix>` appears twice in the same document meaning two different things — once at the
        // top level echoing the request, once inside each `<CommonPrefixes>`. A parser keying on
        // the element name alone invents a folder named after the directory being listed.
        let page = try Self.page(Self.foldersPage)
        #expect(!page.commonPrefixes.contains("tiles/1/"))
    }

    @Test("an error document is not a listing")
    func errorDocumentIsRejected() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message>\
        </Error>
        """
        #expect(throws: S3ListingParseError.notAListing) {
            try S3ListingParser.parse(Data(xml.utf8))
        }
    }

    @Test("an empty folder is an empty page, not a failure")
    func emptyPageIsValid() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <KeyCount>0</KeyCount><IsTruncated>false</IsTruncated></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.objects.isEmpty)
        #expect(page.commonPrefixes.isEmpty)
    }

    // MARK: - Turning a page into rows

    @Test("a folder row is named by its last component, not by its whole key")
    func foldersAreNamedByLeaf() throws {
        let page = try Self.page(Self.foldersPage)
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/tiles/1")
        let entries = S3ListingParser.entries(from: page, in: directory)
        #expect(entries.map(\.name) == ["C", "D"])
        #expect(entries.allSatisfy { $0.kind == .directory })
    }

    /// A common prefix is not an object, so it has no `LastModified` and must say so rather than
    /// carry a date-shaped value. Rendered, the difference is a dash against **01.01.1, 02:02** —
    /// found by browsing a real bucket, since nothing in a listing fixture looks wrong.
    @Test("a folder row reports that it has no date")
    func foldersHaveNoDate() throws {
        let page = try Self.page(Self.foldersPage)
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/tiles/1")
        let entries = S3ListingParser.entries(from: page, in: directory)
        // Hoisted: `allSatisfy` inside `#expect(...)` does not compile (docs/NOTES.md ▸ Testing).
        let noneHasADate = entries.allSatisfy { !$0.hasModificationDate }
        let allAreUnknown = entries.allSatisfy { $0.modificationDate == FileEntry.unknownDate }
        #expect(noneHasADate)
        #expect(allAreUnknown)
    }

    @Test("an object row keeps the date the server sent")
    func objectsKeepTheirDate() throws {
        let page = try Self.page(Self.filesPage)
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        let files = S3ListingParser.entries(from: page, in: directory).filter { !$0.isDirectory }
        let allDated = files.allSatisfy(\.hasModificationDate)
        #expect(!files.isEmpty)
        #expect(allDated)
    }

    @Test("a row's path is built under the directory being listed")
    func rowPathsAreNested() throws {
        let page = try Self.page(Self.foldersPage)
        let backend = VFSBackendID("s3://K@h:443/r/b")
        let directory = VFSPath(backend: backend, path: "/tiles/1")
        let entries = S3ListingParser.entries(from: page, in: directory)
        #expect(entries.first?.path == VFSPath(backend: backend, path: "/tiles/1/C"))
    }

    @Test("the folder's own directory marker is dropped from its listing")
    func directoryMarkerIsDropped() throws {
        // The zero-byte `docs/` object is how an empty folder is held in a flat store, and a
        // listing of `prefix=docs/` returns it as an ordinary row. Rendered, it is a duplicate of
        // the folder drawn inside itself — `displayName("docs/")` is "docs".
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix>docs/</Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>docs/</Key><LastModified>2026-08-12T20:16:42.000Z</LastModified>\
        <Size>0</Size></Contents>\
        <Contents><Key>docs/report.pdf</Key><LastModified>2026-08-12T20:16:42.000Z</LastModified>\
        <Size>12</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/docs")
        let entries = S3ListingParser.entries(from: page, in: directory)
        #expect(entries.map(\.name) == ["report.pdf"])
    }

    @Test("a marker deeper in the tree is not dropped — it is a real empty folder")
    func nestedMarkerSurvives() throws {
        // The narrowness control for the rule above: only the marker *of the listed prefix* is a
        // duplicate. `docs/sub/` inside a listing of `docs/` is the one row an empty subfolder has.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix>docs/</Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>docs/sub/</Key><LastModified>2026-08-12T20:16:42.000Z</LastModified>\
        <Size>0</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/docs")
        let entries = S3ListingParser.entries(from: page, in: directory)
        #expect(entries.map(\.name) == ["sub"])
    }

    @Test("keys are decoded only when the server says the page is url-encoded")
    func decodesOnlyWhenEchoed() throws {
        let encoded = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>\
        <Contents><Key>my%20file.txt</Key><Size>1</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(encoded.utf8))
        #expect(page.isURLEncoded)
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        #expect(S3ListingParser.entries(from: page, in: directory).map(\.name) == ["my file.txt"])
    }

    @Test("a literal percent in a key survives a page that is not url-encoded")
    func doesNotDecodeUnaskedFor() throws {
        // The other half, and the reason `isURLEncoded` is read from the response rather than
        // assumed from the request: `100%.txt` is a legal key, and decoding it unasked would
        // rename it — or drop it, since `%.t` is not valid escaping.
        let plain = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>100%.txt</Key><Size>1</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(plain.utf8))
        #expect(!page.isURLEncoded)
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        #expect(S3ListingParser.entries(from: page, in: directory).map(\.name) == ["100%.txt"])
    }

    @Test("folders sort ahead of files within a page")
    func foldersComeFirst() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>a.txt</Key><Size>1</Size></Contents>\
        <CommonPrefixes><Prefix>z/</Prefix></CommonPrefixes></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        #expect(S3ListingParser.entries(from: page, in: directory).map(\.name) == ["z", "a.txt"])
    }

    // MARK: - The tag reaching the row

    /// A file row carries the tag and a folder row cannot: a common prefix is not an object, so
    /// there is nothing for it to have.
    @Test("a file row carries its ETag and a folder row carries none")
    func rowsCarryTheirETag() throws {
        let directory = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/")
        let files = S3ListingParser.entries(from: try Self.page(Self.filesPage), in: directory)
        let folders = S3ListingParser.entries(from: try Self.page(Self.foldersPage), in: directory)

        #expect(files.first?.entityTag == "\"d7acdb4ab69421f18ae39031a6c226c9\"")
        let untagged = folders.allSatisfy { $0.entityTag == nil }
        #expect(untagged)
    }

    /// The path that actually decides a save, and the one a listing-only test would miss: a
    /// conflict check re-`stat`s, and `S3Backend.stat` answers out of a one-key listing through
    /// `entry(forKey:in:at:)`. A tag that reaches the pane's rows but not this one leaves the
    /// comparison exactly as weak as it was before the field existed (PLAN.md §M21 Slice 10).
    @Test("a stat's row carries the ETag too")
    func statRowCarriesTheETag() throws {
        let path = VFSPath(backend: VFSBackendID("s3://K@h:443/r/b"), path: "/GENERAL_QUALITY.xml")
        let entry = try #require(S3ListingParser.entry(
            forKey: "GENERAL_QUALITY.xml", in: try Self.page(Self.filesPage), at: path
        ))

        #expect(entry.entityTag == "\"d7acdb4ab69421f18ae39031a6c226c9\"")
    }

    @Test("a date the server spells without fractional seconds still reads")
    func readsDateWithoutFraction() throws {
        // Several S3-compatible servers omit the fraction AWS always sends. One
        // `ISO8601DateFormatter` cannot take both — the fractional option makes it required — so
        // this is what stops half the intended servers listing with no dates at all.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key>\
        <LastModified>2017-04-14T14:11:15Z</LastModified><Size>1</Size></Contents>\
        </ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.objects.first?.lastModified == Date(timeIntervalSince1970: 1_492_179_075))
    }
}
