import Foundation

/// The three documents a multipart upload exchanges: the upload id it opens with, the manifest of
/// parts it closes with, and the answer to that close (PLAN.md §M21).
///
/// Pure, so the whole conversation is testable against the bytes a server really sends without a
/// server — the same split every other S3 type in this backend takes.
public enum S3MultipartDocument {
    /// The `CompleteMultipartUpload` request body: every part, in ascending number order.
    ///
    /// **The order is required, not conventional** — S3 assembles the object in the order the
    /// manifest lists and refuses a manifest whose numbers do not ascend (`InvalidPartOrder`), so
    /// this sorts rather than trusting the caller to have collected the parts in sequence. That
    /// matters the moment parts are ever uploaded out of order or retried.
    ///
    /// The ETag is written exactly as the server sent it, quotes and all (``S3UploadedPart``), and
    /// escaped for XML only in the three characters that could end or redirect character data. An
    /// ETag is hex in practice; escaping it anyway costs nothing and means a server whose ETag
    /// format is its own business cannot produce a malformed request.
    public static func manifest(parts: [S3UploadedPart]) -> Data {
        let rows = parts
            .sorted { $0.number < $1.number }
            .map { "<Part><PartNumber>\($0.number)</PartNumber><ETag>\(escaped($0.etag))</ETag></Part>" }
            .joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>\
        <CompleteMultipartUpload>\(rows)</CompleteMultipartUpload>
        """
        return Data(xml.utf8)
    }

    /// The upload id out of an `InitiateMultipartUploadResult`, or `nil` when the body is not one.
    ///
    /// `nil` is a real failure and the caller must treat it as one: without an id there is nothing
    /// to upload parts against, and — more to the point — nothing to *abort*, so an upload that
    /// proceeded on a missing id would be unable to clean up after itself.
    public static func uploadID(from data: Data) -> String? {
        let document = parse(data)
        guard document.root == "InitiateMultipartUploadResult",
              let id = document.values["UploadId"], !id.isEmpty else { return nil }
        return id
    }

    /// The failure a `CompleteMultipartUpload` reported, or `nil` when it really did complete.
    ///
    /// **A completion can fail inside a 200**, which is why this exists rather than the status being
    /// read on its own. S3 may begin the response before it has finished assembling the object —
    /// the connection is held open while it works — and then send an `<Error>` document under the
    /// status it already committed to. A caller reading only the status would report a successful
    /// upload of an object that does not exist: the quiet direction, and on the one operation whose
    /// whole job is to say the file arrived.
    ///
    /// This is AWS's documented behavior rather than something measured here — the local endpoint
    /// the rest of this backend was probed against does not reproduce it. It is handled anyway
    /// because the shape is the one ``S3DeleteResult`` was *measured* to have on a neighbouring
    /// verb, and because the cost of being wrong is asymmetric: reading a body that turns out never
    /// to carry an error costs one parse, while not reading it loses a file.
    public static func completionFailure(from data: Data, status: Int) -> S3ServiceError? {
        let document = parse(data)
        guard document.root == "Error" else { return nil }
        return S3ServiceError(
            status: status,
            code: document.values["Code"] ?? "",
            message: document.values["Message"] ?? ""
        )
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parse(_ data: Data) -> (root: String, values: [String: String]) {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return (delegate.root, delegate.values)
    }

    /// A flat reader that also remembers the **root element**, which is the whole point: the two
    /// answers a completion can give are told apart by their root name and by nothing else — a
    /// `CompleteMultipartUploadResult` and an `<Error>` share the status, and one of them carries an
    /// `<ETag>` the other does not, which is a weaker signal than the name.
    private final class Delegate: NSObject, XMLParserDelegate {
        var root = ""
        var values: [String: String] = [:]
        private var text = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            if root.isEmpty { root = elementName }
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
            if !value.isEmpty, values[elementName] == nil {
                values[elementName] = value
            }
            text = ""
        }
    }
}
