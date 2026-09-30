import Foundation

/// One bucket in a `ListAllMyBuckets` response.
public struct S3Bucket: Sendable, Equatable {
    /// The bucket's name — the only field the service is required to send, and the only one the
    /// picker cannot do without.
    public let name: String
    /// When the bucket was created, or `nil` when the stamp was absent or in a shape
    /// ``S3Date`` cannot read. Display only: it is what lets a long list be ordered by something
    /// other than the alphabet, and nothing depends on it.
    public let creationDate: Date?
    /// The region the bucket lives in, when the server named it.
    ///
    /// AWS added `<BucketRegion>` to this response in 2024 and S3-compatible servers largely do not
    /// send it, so it is optional by construction rather than defensively. It is worth reading
    /// because a bucket list spans regions while the connect form's region field holds exactly one:
    /// picking a bucket can fill in the region it actually lives in instead of leaving the user to
    /// discover it through a 301. When it is absent nothing is lost — addressing the bucket through
    /// the wrong region answers **301 naming the right one**, and `PanelViewController+ConnectS3`
    /// already corrects itself on exactly that.
    public let region: String?

    public init(name: String, creationDate: Date? = nil, region: String? = nil) {
        self.name = name
        self.creationDate = creationDate
        self.region = region
    }
}

/// One page of a `ListAllMyBuckets` response.
public struct S3BucketList: Sendable, Equatable {
    public let buckets: [S3Bucket]
    /// The token the next page must be asked for with, or `nil` when this is the whole list.
    public let nextContinuationToken: String?

    public init(buckets: [S3Bucket], nextContinuationToken: String? = nil) {
        self.buckets = buckets
        self.nextContinuationToken = nextContinuationToken
    }
}

/// Parses a `ListAllMyBuckets` XML response — the buckets one access key can see.
///
/// **Unlike ``S3ListingParser``, this one is not scored against captured bytes**, and saying so is
/// the honest version: `ListAllMyBuckets` is account-scoped, so there is no public bucket to capture
/// a real response from the way the `sentinel-s2-l1c` listings were captured, and this Mac carries
/// no AWS credentials. The fixtures are therefore built from the S3 API reference. Everything the
/// parser does about that is in one direction — **read what is there, require only the name** — so
/// the failure a from-the-docs implementation risks is a field silently missing rather than a page
/// silently dropped:
///
/// - `<CreationDate>` and `<BucketRegion>` are optional, so a server sending neither still lists.
/// - `<Owner>` is ignored rather than required, which is the mistake the real-bytes listing
///   fixtures caught for `<Contents>` and is worth not repeating from the other side.
/// - **Both continuation spellings are read.** The reference gives this response `<ContinuationToken>`
///   where every other paginated S3 response spells the same idea `<NextContinuationToken>`, and
///   with no captured bytes there is nothing here to settle which a given server sends. Reading both
///   has no failure mode; reading one risks a list that stops early and looks complete.
public enum S3BucketListParser {
    /// Parse one page, or throw when the bytes are not a `ListAllMyBucketsResult` at all — in
    /// practice an `<Error>` document, which the caller classifies with ``S3ServiceError`` instead.
    ///
    /// An **empty** `<Buckets>` is not an error: an account with no buckets is an ordinary answer,
    /// and one the picker has to be able to say out loud rather than treat as a failure.
    public static func parse(_ data: Data) throws -> S3BucketList {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawResult else {
            throw S3ListingParseError.notABucketList
        }
        return S3BucketList(
            buckets: delegate.buckets,
            nextContinuationToken: delegate.nextContinuationToken
        )
    }
}

/// Walk every page of an account's bucket list.
///
/// A free function over an injected `fetch` rather than a method on anything, because the two
/// halves belong in different places: *deciding when to stop* is a rule and lives here with tests,
/// while issuing the request is non-hermetic and lives in the app (PLAN.md §2). The same split
/// ``S3Backend/listDirectory(at:)`` makes for object pages, and it carries the same two guards for
/// the same reasons — a server that repeats a token it already gave is disagreeing with itself and
/// would spin forever, and a run past `pageLimit` is refused rather than silently truncated.
///
/// `pageLimit` is small where the object listing's is 1000: this response is not paginated at all
/// unless `max-buckets` is sent, and it is deliberately not sent
/// (``S3ProcessArguments/listBuckets(account:continuationToken:connectTimeout:maxTime:)``), so more
/// than a few pages means something is wrong rather than that somebody owns a lot of buckets.
public enum S3BucketEnumeration {
    public static func allBuckets(
        pageLimit: Int = 20,
        fetch: (String?) throws -> S3BucketList
    ) throws -> [S3Bucket] {
        var buckets: [S3Bucket] = []
        var token: String?
        var pages = 0

        while true {
            let page = try fetch(token)
            buckets += page.buckets
            pages += 1
            guard let next = page.nextContinuationToken, !next.isEmpty else { return buckets }
            guard next != token else { throw S3ListingParseError.bucketListDidNotAdvance }
            guard pages < pageLimit else { throw S3ListingParseError.bucketListTooLong }
            token = next
        }
    }
}

private extension S3BucketListParser {
    /// Accumulates one page.
    ///
    /// The element stack is **symmetry with ``S3ListingParser``, not a rule this document needs** —
    /// worth saying because the opposite was written here first and a negative control disproved it.
    /// There, `<Prefix>` genuinely means two things depending on its parent; here the owner block
    /// carries `<ID>` and `<DisplayName>` and there is no bare `<Name>` outside `<Bucket>` at all,
    /// so matching on the element name alone parses these bytes identically. It is kept because it
    /// costs nothing and because the two parsers being one shape is worth more than the four lines,
    /// but no test can pin it and none pretends to.
    final class Delegate: NSObject, XMLParserDelegate {
        var buckets: [S3Bucket] = []
        var nextContinuationToken: String?
        var sawResult = false

        private var stack: [String] = []
        private var text = ""
        private var name: String?
        private var creationDate: Date?
        private var region: String?
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
            if elementName == "ListAllMyBucketsResult" { sawResult = true }
            if elementName == "Bucket" {
                name = nil
                creationDate = nil
                region = nil
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
            case ("Bucket", "Name"): name = value
            case ("Bucket", "CreationDate"): creationDate = dates.parse(value)
            case ("Bucket", "BucketRegion") where !value.isEmpty: region = value
            case ("ListAllMyBucketsResult", "ContinuationToken") where !value.isEmpty,
                 ("ListAllMyBucketsResult", "NextContinuationToken") where !value.isEmpty:
                nextContinuationToken = value
            case (_, "Bucket"):
                if let name, !name.isEmpty {
                    buckets.append(
                        S3Bucket(name: name, creationDate: creationDate, region: region)
                    )
                }
            default: break
            }
        }
    }
}
