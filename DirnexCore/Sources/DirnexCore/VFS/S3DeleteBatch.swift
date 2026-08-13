import CryptoKit
import Foundation

/// The `DeleteObjects` request — S3's one bulk verb, and the reason deleting a folder over this
/// backend is affordable (PLAN.md §M21).
///
/// A "folder" is a key prefix, so removing one means removing every key under it. One `DELETE` per
/// key is the obvious shape and it bills one request per object: a prefix holding 50 000 files is
/// 50 000 billable requests and 50 000 round trips. `POST ?delete` takes up to **1000** keys in one
/// request, which is the same work for a thousandth of the requests.
///
/// The price is that a batch reports its failures *in the response body* rather than as a status:
/// a 200 can carry per-key `<Error>` rows for keys that were not deleted. A caller reading only the
/// status would report a successful delete of files that are still there — the quiet direction —
/// which is why ``S3DeleteResult`` exists and why the backend surfaces its `errors`.
public enum S3DeleteBatch {
    /// The most keys one request may carry. S3's own documented ceiling; a request over it is
    /// rejected outright rather than truncated.
    public static let maximumKeys = 1000

    /// Split `keys` into requests, each within ``maximumKeys``.
    public static func chunks(of keys: [String]) -> [[String]] {
        stride(from: 0, to: keys.count, by: maximumKeys).map {
            Array(keys[$0..<min($0 + maximumKeys, keys.count)])
        }
    }

    /// The request document for one chunk.
    ///
    /// `<Quiet>true</Quiet>` asks the server to list only what *failed*, which is the half a caller
    /// acts on — and on a 1000-key delete it is the difference between a response naming every key
    /// and one that is usually empty.
    ///
    /// Key text is XML-escaped, which is not a formality here: an object key may legally contain
    /// `&` and `<`, and a key carrying either would otherwise produce a malformed request — or, with
    /// `]]>`-style input, a document that parses as something *other* than the keys asked for. Only
    /// the three characters that can end or redirect character data need escaping in an element's
    /// content; quotes matter in attributes, which this document has none of, and are left alone so
    /// the bytes stay the key.
    public static func document(keys: [String]) -> Data {
        let objects = keys
            .map { "<Object><Key>\(escaped($0))</Key></Object>" }
            .joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <Delete>\(objects)<Quiet>true</Quiet></Delete>
        """
        return Data(xml.utf8)
    }

    /// The `Content-MD5` header value for a request body: base64 of the raw digest, **not** hex.
    ///
    /// S3 requires this header on `DeleteObjects` and rejects the request without it. `curl` signs
    /// whatever `Content-MD5` it is given — measured 2026-08-13, it appears in `SignedHeaders` as
    /// `content-md5;content-type;host;x-amz-content-sha256;x-amz-date` — but it does not *compute*
    /// one, so the value is ours to produce. MD5 is an integrity check chosen by the protocol, not
    /// a security claim, which is why `Insecure.MD5` is the right spelling and not a compromise.
    public static func contentMD5(for body: Data) -> String {
        Data(Insecure.MD5.hash(data: body)).base64EncodedString()
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// What one `DeleteObjects` request reported: the keys it removed, and the ones it refused.
///
/// Both halves are carried because a batch can partially succeed. With `<Quiet>` on, `deleted` is
/// normally empty and `errors` is the whole answer — but the field is parsed anyway, since a server
/// that ignores `Quiet` is answering a question nobody asked rather than failing, and dropping its
/// answer would make a successful delete look like it did nothing.
public struct S3DeleteResult: Sendable, Equatable {
    /// Keys the server confirmed it removed.
    public let deleted: [String]
    /// Keys it did not, each with S3's own code and message.
    public let errors: [S3DeleteFailure]

    public init(deleted: [String] = [], errors: [S3DeleteFailure] = []) {
        self.deleted = deleted
        self.errors = errors
    }
}

/// One key a batch delete refused, and why.
public struct S3DeleteFailure: Sendable, Equatable {
    public let key: String
    /// S3's machine-readable code — `AccessDenied` on a key a bucket policy protects being the one
    /// that actually happens.
    public let code: String
    /// The server's English message. Diagnostic only, never the user-facing sentence — the remote's
    /// words, in a language nobody chose (NOTES.md ▸ Localization).
    public let message: String

    public init(key: String, code: String, message: String) {
        self.key = key
        self.code = code
        self.message = message
    }
}

public extension S3DeleteResult {
    /// Parse a `DeleteResult` document.
    ///
    /// A body that is not one — a proxy's page, an empty 200 — parses to an empty result rather
    /// than throwing, matching how ``S3ServiceError`` treats an unrecognized error document: the
    /// status has already said the request succeeded, and inventing a failure from an unreadable
    /// body would report deletions that did happen as failures.
    static func parse(_ data: Data) -> S3DeleteResult {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return S3DeleteResult(deleted: delegate.deleted, errors: delegate.errors)
    }

    /// A private delegate rather than a shared one: `DeleteResult` nests `<Key>` under **two**
    /// different parents (`<Deleted>` and `<Error>`), so unlike the flat `<Error>` document this
    /// cannot be read with a name-keyed dictionary — the parent decides which list a key joins.
    private final class Delegate: NSObject, XMLParserDelegate {
        var deleted: [String] = []
        var errors: [S3DeleteFailure] = []

        private var text = ""
        private var key = ""
        private var code = ""
        private var message = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            // Both containers reset the fields they will fill, so a row missing an element cannot
            // inherit the previous row's value — the shape that turns one `AccessDenied` into a
            // whole batch of them.
            if elementName == "Error" || elementName == "Deleted" {
                (key, code, message) = ("", "", "")
            }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch elementName {
            // Untrimmed, for the reason `S3ListingParser` spells out: an edge space is part of the
            // key. Here it only reaches an error message — `S3Backend.failure` builds the failing
            // object's path from it — so a trimmed key names a file one character off from the one
            // the server refused, which is the least helpful possible way to report a refusal.
            case "Key": key = text
            case "Code": code = value
            case "Message": message = value
            case "Deleted" where !key.isEmpty: deleted.append(key)
            case "Error":
                errors.append(S3DeleteFailure(key: key, code: code, message: message))
            default: break
            }
            text = ""
        }
    }
}
