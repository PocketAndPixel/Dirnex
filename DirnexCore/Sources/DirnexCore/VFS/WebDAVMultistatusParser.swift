import Foundation

/// One `<response>` out of a WebDAV `207 Multi-Status` body: a resource and the properties the
/// server found for it, or a resource and the status an operation on it ended with.
public struct WebDAVResponse: Sendable, Equatable {
    /// The decoded server path (``WebDAVHref/serverPath(fromHref:)``), not the raw href.
    public let path: String
    /// The response's own `<status>`, which a body describing a failed DELETE, COPY or MOVE carries
    /// for each member it could not act on. `nil` for a row of properties, which carries its
    /// statuses per `<propstat>` instead.
    public let status: Int?
    /// Whether `<resourcetype>` held `<collection/>`. The only test of a folder that holds: the
    /// NAS's account root lists its shared folders with no trailing slash (2026-10-22).
    public let isCollection: Bool
    /// `<getcontentlength>`, or `nil` when the server sent none. A collection has none on Apache —
    /// it comes back in a 404 `propstat`.
    public let byteSize: Int64?
    /// `<getlastmodified>`, an HTTP date with one-second resolution.
    public let modified: Date?
    /// `<creationdate>`, an RFC 3339 stamp.
    public let created: Date?
    /// `<getetag>`, kept verbatim, quotes and any `W/` included, for the reason
    /// ``S3Object/entityTag`` gives: it is only ever compared against another reading of the same
    /// resource, and tidying it is the edit that makes two readings disagree.
    ///
    /// The `W/` matters here as it does not for S3. Apache marks a tag weak when the file was
    /// written in the same second it is read, and `If-Match` with a weak tag answers **412** for a
    /// file nobody else touched; two seconds later the same file reads back with the strong form of
    /// the same tag (measured on the NAS, 2026-10-22). A write-back guarded by a tag has to know.
    public let entityTag: String?
    /// `<getcontenttype>`, or `nil`.
    public let contentType: String?

    public init(
        path: String,
        status: Int? = nil,
        isCollection: Bool = false,
        byteSize: Int64? = nil,
        modified: Date? = nil,
        created: Date? = nil,
        entityTag: String? = nil,
        contentType: String? = nil
    ) {
        self.path = path
        self.status = status
        self.isCollection = isCollection
        self.byteSize = byteSize
        self.modified = modified
        self.created = created
        self.entityTag = entityTag
        self.contentType = contentType
    }
}

/// A whole `207 Multi-Status` body.
public struct WebDAVMultistatus: Sendable, Equatable {
    /// Every response that named a readable resource, in the server's order — which is not a
    /// contract: the NAS and macOS's Apache list the same folder in different orders.
    public let responses: [WebDAVResponse]
    /// How many hrefs could not be made into a path (``WebDAVHref/serverPath(fromHref:)`` says
    /// which and why). Counted rather than dropped in silence, so a listing missing rows can say so.
    public let unreadableHrefCount: Int
}

/// Why a body could not be read as what was asked for.
public enum WebDAVParseError: Error, Sendable, Equatable {
    /// The bytes are not a `DAV:` `multistatus` document — an HTML error page, an empty body, or a
    /// proxy's answer.
    case notAMultistatus
    /// A listing named no row as the folder that was listed, and no row that every other row sits
    /// inside, so nothing can say which rows are its children (``WebDAVMultistatus/listing(of:)``).
    case listingDoesNotNameItsFolder
}

/// Parses a WebDAV `207 Multi-Status` body.
///
/// Scored against bytes captured from two servers rather than written from RFC 4918 (the fixtures
/// under `Fixtures/WebDAV`). Both are Apache `mod_dav`, and what they settled is what a parser
/// written from the RFC's examples gets wrong:
///
/// - **Elements are matched by namespace URI, never by prefix.** The live properties arrive as
///   `<lp1:getlastmodified>`, `lp1` bound to `DAV:` on each `<response>`, while `href`, `prop` and
///   `status` use `D:`. A parser matching `D:` reads every row and finds no size, date or type.
/// - **Only a `propstat` whose status is 2xx counts.** Asked for named properties, Apache answers a
///   collection's `getcontentlength` in a second `propstat` marked 404.
/// - **An `href` counts only directly under `<response>`.** A locked file's `<lockdiscovery>`
///   carries one too, `opaquelocktoken:…`, inside `<locktoken>`.
public enum WebDAVMultistatusParser {
    /// The `DAV:` namespace every element this reads belongs to.
    static let davNamespace = "DAV:"

    /// Parse a body, or throw ``WebDAVParseError/notAMultistatus`` when it is not one.
    ///
    /// A multistatus with no responses is not an error here: an error body can name no members,
    /// and a listing without even its own folder is the listing's problem (``listing(of:)``).
    public static func parse(_ data: Data) throws -> WebDAVMultistatus {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), delegate.sawMultistatus else { throw WebDAVParseError.notAMultistatus }
        return WebDAVMultistatus(
            responses: delegate.responses,
            unreadableHrefCount: delegate.unreadableHrefCount
        )
    }

    /// The code out of an HTTP status line — `HTTP/1.1 423 Locked` → 423, and Apache's
    /// `HTTP/1.1 409 (status)` → 409 — or `nil`.
    static func statusCode(fromLine line: String) -> Int? {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2, tokens[0].hasPrefix("HTTP/"),
              tokens[1].count == 3, let code = Int(tokens[1])
        else { return nil }
        return code
    }
}

private extension WebDAVMultistatusParser {
    /// Accumulates the responses. The element path is kept on a stack because what an element
    /// means depends on where it sits: `href` under `response` names the resource and under
    /// `locktoken` names a lock, and `status` under `propstat` qualifies some properties while under
    /// `response` it is an operation's outcome.
    final class Delegate: NSObject, XMLParserDelegate {
        var responses: [WebDAVResponse] = []
        var unreadableHrefCount = 0
        var sawMultistatus = false

        /// The element path, each entry `nil` when the element is outside `DAV:`.
        private var stack: [String?] = []
        private var text = ""
        private let dates = WebDAVDate()

        // One response.
        private var hrefs: [String] = []
        private var responseStatus: Int?
        private var accepted = WebDAVPropertyValues()
        private var sawAcceptedPropstat = false

        // One propstat, accepted into the response only once its status turns out to be 2xx —
        // which XML puts *after* the properties, so they are held until then.
        private var pending = WebDAVPropertyValues()
        private var propstatStatus: Int?

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            let name = namespaceURI == WebDAVMultistatusParser.davNamespace ? elementName : nil
            stack.append(name)
            text = ""
            switch name {
            case "multistatus" where stack.count == 1:
                sawMultistatus = true
            case "response" where isPath(["multistatus", "response"]):
                hrefs = []
                responseStatus = nil
                accepted = WebDAVPropertyValues()
                sawAcceptedPropstat = false
            case "propstat" where isPath(["response", "propstat"]):
                pending = WebDAVPropertyValues()
                propstatStatus = nil
            // An empty element, so it is handled on the way in: `<resourcetype><collection/>`.
            case "collection" where isPath(["propstat", "prop", "resourcetype", "collection"]):
                pending.isCollection = true
            default:
                break
            }
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
            defer {
                stack.removeLast()
                text = ""
            }
            guard let last = stack.last, let name = last else { return }
            // Every value read here is a number, a date, a token or a path, so whitespace at its
            // edges is XML formatting. An href's own spaces are encoded (`%20`), as measured.
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if isPath(["propstat", "prop", name]) {
                readProperty(name, value: value)
                return
            }
            switch name {
            case "href" where isPath(["response", "href"]):
                hrefs.append(value)
            case "status" where isPath(["propstat", "status"]):
                propstatStatus = WebDAVMultistatusParser.statusCode(fromLine: value)
            case "status" where isPath(["response", "status"]):
                responseStatus = WebDAVMultistatusParser.statusCode(fromLine: value)
            case "propstat" where isPath(["response", "propstat"]):
                if let propstatStatus, (200...299).contains(propstatStatus) {
                    accepted.merge(pending)
                    sawAcceptedPropstat = true
                }
            case "response" where isPath(["multistatus", "response"]):
                finishResponse()
            default:
                break
            }
        }

        private func readProperty(_ name: String, value: String) {
            switch name {
            case "getcontentlength":
                pending.byteSize = Int64(value).flatMap { $0 >= 0 ? $0 : nil }
            case "getlastmodified":
                pending.modified = dates.httpDate(value)
            case "creationdate":
                pending.created = dates.creationDate(value)
            // Empty is `nil`, so "no tag" and "an empty tag" reach a comparison as the same answer
            // — no evidence — rather than as a tag that matches every other empty one.
            case "getetag" where !value.isEmpty:
                pending.entityTag = value
            case "getcontenttype" where !value.isEmpty:
                pending.contentType = value
            default:
                break
            }
        }

        /// Emit what one `<response>` said. A row of properties takes its one href; an outcome
        /// takes every href it lists, since RFC 4918 lets one `<status>` cover several resources.
        private func finishResponse() {
            if sawAcceptedPropstat {
                guard let href = hrefs.first else { return }
                guard let path = WebDAVHref.serverPath(fromHref: href) else {
                    unreadableHrefCount += 1
                    return
                }
                responses.append(WebDAVResponse(
                    path: path,
                    isCollection: accepted.isCollection,
                    byteSize: accepted.byteSize,
                    modified: accepted.modified,
                    created: accepted.created,
                    entityTag: accepted.entityTag,
                    contentType: accepted.contentType
                ))
            } else if let responseStatus {
                for href in hrefs {
                    guard let path = WebDAVHref.serverPath(fromHref: href) else {
                        unreadableHrefCount += 1
                        continue
                    }
                    responses.append(WebDAVResponse(path: path, status: responseStatus))
                }
            }
        }

        /// Whether the element path ends with `suffix`, every element in it in `DAV:`.
        private func isPath(_ suffix: [String]) -> Bool {
            guard stack.count >= suffix.count else { return false }
            return zip(stack.suffix(suffix.count), suffix).allSatisfy { $0 == $1 }
        }
    }
}

/// The properties one `propstat` carried, or a whole response's once its 2xx ones are merged.
private struct WebDAVPropertyValues {
    var isCollection = false
    var byteSize: Int64?
    var modified: Date?
    var created: Date?
    var entityTag: String?
    var contentType: String?

    mutating func merge(_ other: WebDAVPropertyValues) {
        isCollection = isCollection || other.isCollection
        byteSize = other.byteSize ?? byteSize
        modified = other.modified ?? modified
        created = other.created ?? created
        entityTag = other.entityTag ?? entityTag
        contentType = other.contentType ?? contentType
    }
}

/// Reads the two date shapes WebDAV uses.
///
/// `getlastmodified` is an HTTP date, `Thu, 22 Oct 2026 20:48:28 GMT` on both servers measured.
/// RFC 9110 obliges a recipient to accept two obsolete forms as well, RFC 850's
/// `Thursday, 22-Oct-26 20:48:28 GMT` and C's `asctime` `Thu Oct 22 20:48:28 2026`, so those are
/// read too. `creationdate` is RFC 3339, read with ``S3Date``, which already takes a stamp with or
/// without fractional seconds. Each falls back to the other's shape, since a server that sends the
/// wrong one still means a date.
///
/// Held per parse rather than in a `static`, for the reason ``S3Date`` gives: `DateFormatter` is
/// not `Sendable`.
struct WebDAVDate {
    private let httpFormats: [DateFormatter]
    private let iso = S3Date()

    init() {
        httpFormats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            return formatter
        }
    }

    func httpDate(_ value: String) -> Date? {
        for formatter in httpFormats {
            if let date = formatter.date(from: value) { return date }
        }
        return iso.parse(value)
    }

    /// A `creationdate` at the Unix epoch is no date at all. Nextcloud 34 sends
    /// `1970-01-01T00:00:00+00:00` for every row whose creation it never recorded, which is every
    /// file a client uploaded (measured 2026-10-24), and taken as a date it would show each one in
    /// Get Info as made in 1970. Absent, the row falls back to its modification date, as it does
    /// on a server that sends none.
    func creationDate(_ value: String) -> Date? {
        guard let date = iso.parse(value) ?? httpDate(value) else { return nil }
        return date.timeIntervalSince1970 == 0 ? nil : date
    }
}
