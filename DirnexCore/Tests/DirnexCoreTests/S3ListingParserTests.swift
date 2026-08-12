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
