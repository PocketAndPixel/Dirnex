import Foundation
import Testing

@testable import DirnexCore

/// Names whose edges are whitespace — a rule `S3ListingParserTests` cannot cover, because its
/// fixtures are AWS's and AWS structurally cannot produce this shape.
///
/// These are **real bytes** from a third-party S3-compatible endpoint, captured 2026-08-13 against
/// `s3.lax.sharktech.net` with a live account. That server ignores `encoding-type=url` — it echoes
/// no `<EncodingType>` and returns keys raw — so an edge space arrives as itself, where AWS would
/// have sent `%20` and hidden the whole class.
///
/// What it hid was a blanket `trimmingCharacters` over every parsed element, which cost three verbs
/// on one row: download and rename answered `notFound` for a file visible in the pane, and delete
/// **reported success having deleted nothing**. `stat` kept matching throughout, because the trim
/// was applied to both sides of its comparison — which is what kept it quiet.
@Suite("S3 listings: whitespace at a name's edges")
struct S3ListingWhitespaceTests {
    private static let directory = VFSPath(backend: VFSBackendID("s3p://K@h:443/r/b"), path: "/")

    @Test("a key ending in a space keeps it")
    func keepsTrailingSpaceInKey() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>name </Key><Size>2</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.objects.map(\.key) == ["name "])
        #expect(S3ListingParser.entries(from: page, in: Self.directory).map(\.name) == ["name "])
    }

    @Test("a key beginning with a space keeps it")
    func keepsLeadingSpaceInKey() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key> notes.txt</Key><Size>2</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.objects.map(\.key) == [" notes.txt"])
        #expect(
            S3ListingParser.entries(from: page, in: Self.directory).map(\.name) == [" notes.txt"]
        )
    }

    @Test("a common prefix beginning with a space keeps it")
    func keepsLeadingSpaceInCommonPrefix() throws {
        // The folder half, and the worse symptom of the two: trimmed, the row drew as `folder`,
        // and entering it listed with `prefix=folder/` — a prefix matching nothing — so the folder
        // opened *empty* rather than failing.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix></Prefix><IsTruncated>false</IsTruncated><Delimiter>/</Delimiter>\
        <CommonPrefixes><Prefix> folder/</Prefix></CommonPrefixes></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.commonPrefixes == [" folder/"])
        let entries = S3ListingParser.entries(from: page, in: Self.directory)
        #expect(entries.map(\.name) == [" folder"])
        #expect(entries.first?.isDirectory == true)
    }

    @Test("an edge-space key is reachable by the path the listing gave it")
    func statMatchesTheListedName() throws {
        // The end-to-end claim, and the one the bug broke: whatever `entries` names a row, that
        // same key must be what `entry(forKey:)` matches. Trimmed, the two disagreed by one
        // character and every byte-touching verb missed.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <Prefix>edge2/name </Prefix><IsTruncated>false</IsTruncated>\
        <Contents><Key>edge2/name </Key><Size>2</Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        let path = VFSPath(backend: VFSBackendID("s3p://K@h:443/r/b"), path: "/edge2/name ")
        #expect(S3ListingParser.entry(forKey: "edge2/name ", in: page, at: path)?.byteSize == 2)
        // And the trimmed spelling must *not* answer, or the bug is merely inverted.
        #expect(S3ListingParser.entry(forKey: "edge2/name", in: page, at: path) == nil)
    }

    @Test("the fields that are not names are still trimmed")
    func stillTrimsNonNameFields() throws {
        // The negative control: dropping the trim wholesale would make a pretty-printed size or
        // date unreadable, so the trim has to stay exactly where whitespace cannot be data.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>b</Name>\
        <IsTruncated>
        true
        </IsTruncated><NextContinuationToken>
        tok==
        </NextContinuationToken><Contents><Key>a.txt</Key><LastModified>
        2017-04-14T14:11:15Z
        </LastModified><Size>
        3194
        </Size></Contents></ListBucketResult>
        """
        let page = try S3ListingParser.parse(Data(xml.utf8))
        #expect(page.isTruncated)
        #expect(page.nextContinuationToken == "tok==")
        #expect(page.objects.first?.size == 3194)
        #expect(page.objects.first?.lastModified == Date(timeIntervalSince1970: 1_492_179_075))
    }
}
