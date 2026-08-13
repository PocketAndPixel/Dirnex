import Foundation
import Testing

@testable import DirnexCore

/// `DeleteObjects` — the request document, its required integrity header, and the response that is
/// the real outcome (PLAN.md §M21).
@Suite("S3 delete batch")
struct S3DeleteBatchTests {
    // MARK: - The request

    @Test("keys are split into requests of at most a thousand")
    func chunksAtTheCeiling() {
        let keys = (0..<2500).map { "docs/file-\($0).txt" }
        let chunks = S3DeleteBatch.chunks(of: keys)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 1000)
        #expect(chunks[1].count == 1000)
        #expect(chunks[2].count == 500)
        // Nothing is dropped and nothing is duplicated, which a count alone would not catch.
        #expect(chunks.flatMap { $0 } == keys)
    }

    @Test("an exact multiple produces no trailing empty request")
    func chunksAnExactMultiple() {
        let chunks = S3DeleteBatch.chunks(of: (0..<2000).map(String.init))
        #expect(chunks.count == 2)
    }

    @Test("no keys means no requests")
    func chunksNothing() {
        #expect(S3DeleteBatch.chunks(of: []).isEmpty)
    }

    @Test("the document names every key and asks for the quiet form")
    func documentShape() throws {
        let data = S3DeleteBatch.document(keys: ["a.txt", "docs/b.txt"])
        let xml = try #require(String(data: data, encoding: .utf8))
        #expect(xml.contains("<Object><Key>a.txt</Key></Object>"))
        #expect(xml.contains("<Object><Key>docs/b.txt</Key></Object>"))
        // Quiet asks the server to list only failures, which on a 1000-key delete is the difference
        // between a response naming every key and one that is usually empty.
        #expect(xml.contains("<Quiet>true</Quiet>"))
    }

    @Test("a key carrying XML metacharacters is escaped, not passed through")
    func escapesKeyText() throws {
        // All three are legal in an object key, and a raw `&` alone makes the request malformed.
        let data = S3DeleteBatch.document(keys: ["a&b.txt", "<script>.txt", "x>y.txt"])
        let xml = try #require(String(data: data, encoding: .utf8))
        #expect(xml.contains("<Key>a&amp;b.txt</Key>"))
        #expect(xml.contains("<Key>&lt;script&gt;.txt</Key>"))
        #expect(xml.contains("<Key>x&gt;y.txt</Key>"))
    }

    @Test("the escaped document parses back to the keys that went in")
    func escapedDocumentRoundTrips() {
        // The assertion that matters is not the escaping's spelling but that an XML reader recovers
        // the original bytes — a hand-rolled escape that is merely *different* still round-trips
        // wrongly, and the string assertions above cannot see it.
        let keys = ["a&b.txt", "<script>.txt", "quote\".txt", "docs/plain.txt"]
        let document = S3DeleteBatch.document(keys: keys)
        let delegate = KeyCollector()
        let parser = XMLParser(data: document)
        parser.delegate = delegate
        #expect(parser.parse())
        #expect(delegate.keys == keys)
    }

    @Test("Content-MD5 is base64 of the raw digest, not hex")
    func contentMD5Encoding() {
        // Pinned against the published MD5 of the empty string, whose base64 form is a value no
        // implementation of this function could produce by accident.
        #expect(S3DeleteBatch.contentMD5(for: Data()) == "1B2M2Y8AsgTpgAmY7PhCfg==")
        // And a known non-empty vector: MD5("abc") = 900150983cd24fb0d6963f7d28e17f72.
        #expect(S3DeleteBatch.contentMD5(for: Data("abc".utf8)) == "kAFQmDzST7DWlj99KOF/cg==")
    }

    // MARK: - The response

    @Test("a quiet success parses to nothing at all")
    func parsesQuietSuccess() {
        let result = S3DeleteResult.parse(Data(S3Fixtures.deleteQuiet.utf8))
        #expect(result.deleted.isEmpty)
        #expect(result.errors.isEmpty)
    }

    @Test("a 200 carrying a refusal separates what was deleted from what was not")
    func parsesPartialFailure() throws {
        let result = S3DeleteResult.parse(Data(S3Fixtures.deletePartialFailure.utf8))
        #expect(result.deleted == ["docs/a.txt"])
        #expect(result.errors.count == 1)
        let failure = try #require(result.errors.first)
        // `<Key>` nests under two different parents, so the parent decides which list a key joins —
        // the reason this cannot be read with a flat name-keyed dictionary the way `<Error>` is.
        #expect(failure.key == "docs/sub/b.txt")
        #expect(failure.code == "AccessDenied")
    }

    @Test("a second failure does not inherit the first one's fields")
    func doesNotBleedBetweenRows() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeleteResult><Error><Key>a</Key><Code>AccessDenied</Code><Message>no</Message></Error>\
        <Error><Key>b</Key></Error></DeleteResult>
        """
        let result = S3DeleteResult.parse(Data(xml.utf8))
        #expect(result.errors.count == 2)
        // The second row carries no code, and must not borrow `AccessDenied` from the first —
        // which is how one refused key becomes a whole batch of them in a report.
        #expect(result.errors[1].key == "b")
        #expect(result.errors[1].code.isEmpty)
    }

    @Test("a body that is not a DeleteResult parses empty rather than inventing a failure")
    func parsesUnrecognizedBody() {
        let result = S3DeleteResult.parse(Data("<html><body>proxy</body></html>".utf8))
        #expect(result.deleted.isEmpty)
        // The status already said the request succeeded; conjuring a failure from an unreadable
        // body would report deletions that did happen as failures.
        #expect(result.errors.isEmpty)
    }

    @Test("a refused key keeps whitespace at its edges")
    func keepsEdgeWhitespaceInRefusedKey() {
        // Same rule as `S3ListingParser`: the key is a name, so its edges are data. This one only
        // reaches an error message — `S3Backend` builds the failing object's path from it — but a
        // key trimmed by one character names a file the server never mentioned, which is the least
        // useful thing a refusal can say.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <Deleted><Key>kept </Key></Deleted>\
        <Error><Key> refused.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message>\
        </Error></DeleteResult>
        """
        let result = S3DeleteResult.parse(Data(xml.utf8))
        #expect(result.deleted == ["kept "])
        #expect(result.errors.map(\.key) == [" refused.txt"])
        #expect(result.errors.map(\.code) == ["AccessDenied"])
    }
}

/// Reads `<Key>` elements out of a request document, written by hand rather than reusing the
/// production parser — reusing it would prove the two agree, not that either is right.
private final class KeyCollector: NSObject, XMLParserDelegate {
    var keys: [String] = []
    private var inKey = false
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        inKey = elementName == "Key"
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inKey { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        if elementName == "Key" { keys.append(text) }
        inKey = false
        text = ""
    }
}
