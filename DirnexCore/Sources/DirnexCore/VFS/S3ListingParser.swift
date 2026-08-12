import Foundation

/// One object in a `ListObjectsV2` response.
public struct S3Object: Sendable, Equatable {
    /// The **whole** key, not a leaf name — `tiles/1/GENERAL_QUALITY.xml` even in a listing that
    /// asked for `prefix=tiles/`.
    public let key: String
    public let size: Int64
    /// `nil` when the server sent a stamp in a shape this cannot read. A listing is still usable
    /// without it, so an unreadable date must not fail the page.
    public let lastModified: Date?

    public init(key: String, size: Int64, lastModified: Date?) {
        self.key = key
        self.size = size
        self.lastModified = lastModified
    }
}

/// One page of a `ListObjectsV2` response. S3 pages at 1000 keys whatever `max-keys` asks for, so
/// a directory listing is a *loop*, not a call — unlike every other backend in this project.
public struct S3ListingPage: Sendable, Equatable {
    /// The objects, which become file rows.
    public let objects: [S3Object]
    /// The grouped prefixes, which become folder rows. Whole prefixes, like ``S3Object/key``.
    public let commonPrefixes: [String]
    /// The token the next page must be asked for with, or `nil` at the end of the listing.
    public let nextContinuationToken: String?
    /// Whether the server says more pages exist. Kept beside the token rather than derived from it
    /// because they are two claims and a server is free to disagree with itself; the token is what
    /// the loop actually needs, and this is what a test can assert against.
    public let isTruncated: Bool
    /// Whether the server echoed `<EncodingType>url</EncodingType>`, meaning every key and prefix
    /// in this page is percent-encoded and must be decoded before it is shown.
    ///
    /// Read from the response rather than assumed from the request: a server that ignores the
    /// parameter would otherwise have every key decoded anyway, silently turning a literal `%20`
    /// in a legal key name into a space.
    public let isURLEncoded: Bool
}

/// Parses a `ListObjectsV2` XML response.
///
/// Scored against real bytes rather than the documentation: the fixtures come from anonymous
/// listings of the public `sentinel-s2-l1c`, `nasa-nex` and `noaa-goes16` buckets, captured
/// 2026-08-12. That is what settled the two facts a from-the-docs implementation gets wrong —
/// keys and common prefixes arrive **whole** at every depth, and `<Contents>` carries no `<Owner>`
/// unless it was asked for, so a parser requiring one drops every row.
public enum S3ListingParser {
    /// Parse one page, or throw when the bytes are not a `ListBucketResult` at all.
    ///
    /// Note what is deliberately *not* an error: a page with no `<Contents>` and no
    /// `<CommonPrefixes>`. That is what an empty folder looks like, and what the last page of a
    /// listing whose final object landed exactly on a page boundary looks like.
    public static func parse(_ data: Data) throws -> S3ListingPage {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawListBucketResult else {
            throw S3ListingParseError.notAListing
        }
        return S3ListingPage(
            objects: delegate.objects,
            commonPrefixes: delegate.commonPrefixes,
            nextContinuationToken: delegate.nextContinuationToken,
            isTruncated: delegate.isTruncated,
            isURLEncoded: delegate.encodingType == "url"
        )
    }

    /// Turn a page into directory entries for `directory`, dropping what must not be shown.
    ///
    /// Two rows are dropped and both would otherwise be visible bugs rather than noise: the
    /// directory marker for the folder being listed (which renders as a duplicate of the folder
    /// *inside itself* — see ``S3Key/isDirectoryMarker(key:forPrefix:)``), and any key whose
    /// percent-encoding does not decode, which is a name nothing can be made from.
    public static func entries(
        from page: S3ListingPage,
        in directory: VFSPath
    ) -> [FileEntry] {
        let prefix = S3Key.listingPrefix(for: directory)
        let decode = decoder(for: page)

        let folders = page.commonPrefixes.compactMap { raw -> FileEntry? in
            guard let key = decode(raw) else { return nil }
            return entry(key: key, kind: .directory, size: 0, date: nil, in: directory)
        }
        let files = page.objects.compactMap { object -> FileEntry? in
            guard let key = decode(object.key),
                  !S3Key.isDirectoryMarker(key: key, forPrefix: prefix)
            else { return nil }
            return entry(
                key: key,
                kind: .file,
                size: object.size,
                date: object.lastModified,
                in: directory
            )
        }
        return folders + files
    }

    /// The entry for **exactly** `key`, out of a page listed with `prefix=key`, or `nil` when the
    /// page holds no such thing. This is how ``S3Backend`` stats one path in a single request: a
    /// listing whose prefix *is* the key answers both questions at once — a `Contents` row means a
    /// file, and a `CommonPrefixes` entry of `key/` means a folder.
    ///
    /// **The exact match is the whole rule, and a first-row reading is wrong rather than sloppy.**
    /// Probed against a real bucket 2026-08-12: `prefix=README` came back with four rows —
    /// `README.alignment_data`, `README.analysis_history`, `README.complete_genomics_data`,
    /// `README.crams` — and no `README` at all. A stat that took the first row would report a
    /// *sibling's* size and date under the name the caller asked about, which is the quiet
    /// direction: a plausible answer about the wrong file. Same family as the trailing-delimiter
    /// rule in ``S3Key/listingPrefix(for:)`` — a prefix is a string comparison and knows nothing
    /// about path components.
    public static func entry(
        forKey key: String,
        in page: S3ListingPage,
        at path: VFSPath
    ) -> FileEntry? {
        let decode = decoder(for: page)
        if let object = page.objects.first(where: { decode($0.key) == key }) {
            return entry(
                at: path,
                name: path.lastComponent,
                kind: .file,
                size: object.size,
                date: object.lastModified
            )
        }
        guard page.commonPrefixes.contains(where: { decode($0) == "\(key)/" }) else { return nil }
        return entry(at: path, name: path.lastComponent, kind: .directory, size: 0, date: nil)
    }

    /// How a key or prefix from `page` is read back, given whether the server honored
    /// `encoding-type=url`. `nil` for input that does not decode, which is a name nothing can be
    /// made from.
    private static func decoder(for page: S3ListingPage) -> (String) -> String? {
        page.isURLEncoded ? { S3Key.decodingURLEncoding($0) } : { Optional($0) }
    }

    private static func entry(
        key: String,
        kind: FileEntry.Kind,
        size: Int64,
        date: Date?,
        in directory: VFSPath
    ) -> FileEntry? {
        let name = S3Key.displayName(ofKey: key)
        guard !name.isEmpty else { return nil }
        return entry(at: directory.appending(name), name: name, kind: kind, size: size, date: date)
    }

    private static func entry(
        at path: VFSPath,
        name: String,
        kind: FileEntry.Kind,
        size: Int64,
        date: Date?
    ) -> FileEntry {
        // S3 has no mtime you can set and no birth time at all, so both dates are the object's
        // `LastModified` and a folder — which is not an object — has neither.
        // `FileEntry.unknownDate` rather than "now" for that case: a sort by date must not shuffle
        // on every refresh, and the name is what tells the renderer to draw a dash instead of a
        // formatted year 1.
        let modified = date ?? FileEntry.unknownDate
        return FileEntry(
            path: path,
            name: name,
            kind: kind,
            byteSize: size,
            modificationDate: modified,
            creationDate: modified,
            isHidden: name.hasPrefix("."),
            permissions: kind == .directory ? 0o755 : 0o644,
            ownerID: 0,
            groupID: 0,
            flags: 0,
            inode: 0,
            symlinkDestination: nil,
            symlinkTargetKind: nil,
            isDataless: false
        )
    }
}

/// Why a response could not be read as a listing.
public enum S3ListingParseError: Error, Sendable, Equatable {
    /// The bytes parsed as XML but are not a `ListBucketResult` — in practice an `<Error>`
    /// document, which the caller classifies with ``S3ResponseError`` instead.
    case notAListing
}

private extension S3ListingParser {
    /// Accumulates one page. `XMLParser` is push-based, so the element names are tracked on a small
    /// stack rather than by looking at the current element alone: `<Prefix>` means two different
    /// things depending on whether it sits inside `<CommonPrefixes>` or at the top level, where it
    /// merely echoes the request.
    final class Delegate: NSObject, XMLParserDelegate {
        var objects: [S3Object] = []
        var commonPrefixes: [String] = []
        var nextContinuationToken: String?
        var isTruncated = false
        var encodingType: String?
        var sawListBucketResult = false

        private var stack: [String] = []
        private var text = ""
        private var key: String?
        private var size: Int64 = 0
        private var lastModified: Date?
        private let dates = S3Date()

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            stack.append(elementName)
            text = ""
            if elementName == "ListBucketResult" { sawListBucketResult = true }
            if elementName == "Contents" {
                key = nil
                size = 0
                lastModified = nil
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
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            switch (parent, elementName) {
            case ("Contents", "Key"): key = value
            case ("Contents", "Size"): size = Int64(value) ?? 0
            case ("Contents", "LastModified"): lastModified = dates.parse(value)
            case ("CommonPrefixes", "Prefix") where !value.isEmpty:
                commonPrefixes.append(value)
            case ("ListBucketResult", "NextContinuationToken") where !value.isEmpty:
                nextContinuationToken = value
            case ("ListBucketResult", "IsTruncated"): isTruncated = value == "true"
            case ("ListBucketResult", "EncodingType"): encodingType = value
            case (_, "Contents"):
                if let key, !key.isEmpty {
                    objects.append(S3Object(key: key, size: size, lastModified: lastModified))
                }
            default: break
            }
        }
    }
}

/// Reads S3's `LastModified` stamps.
///
/// Two shapes have to be accepted, which is why this holds two formatters: AWS sends
/// `2017-04-14T14:11:15.000Z` (fractional seconds) and several S3-compatible servers send
/// `2017-04-14T14:11:15Z` without them. `ISO8601DateFormatter` will not read both with one option
/// set — the fractional-seconds option makes the fraction *required*, not optional — so a single
/// formatter silently returns `nil` for half the servers this backend exists to reach.
///
/// Instantiated once per parse and held by the delegate rather than kept in a `static`:
/// `ISO8601DateFormatter` is not `Sendable`, so a shared instance does not compile under Swift 6
/// strict concurrency — and building one per *object* would pay that cost thousands of times in a
/// listing, which is exactly where the parser is hot.
struct S3Date {
    private let withFraction: ISO8601DateFormatter
    private let withoutFraction: ISO8601DateFormatter

    init() {
        withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
    }

    func parse(_ value: String) -> Date? {
        withFraction.date(from: value) ?? withoutFraction.date(from: value)
    }
}
