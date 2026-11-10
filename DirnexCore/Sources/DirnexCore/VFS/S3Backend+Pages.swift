import Foundation

/// The pagination loop every `ListObjectsV2` enumeration in this backend goes through, and the two
/// guards that bound it.
///
/// It is its own file because it is its own concept rather than because ``S3Backend`` ran out of
/// room. **A listing here is a loop, not a call** — no other backend in this project has that shape
/// — and three unrelated features rest on it: a directory listing, the recursive sweep a folder
/// delete needs (`S3Backend+Write.swift`), and the flat subtree a search takes
/// (`S3Backend+Subtree.swift`). Each of the three had, or would have had, its own copy of a
/// `while true` whose exits decide whether a partial answer can pass for a complete one. This
/// project's most-repeated finding is one rule spelled several times with the compiler checking
/// none of them; the comments that used to read "the same reason `listDirectory` does" are now the
/// same code.
extension S3Backend {
    /// Every page of one `ListObjectsV2` enumeration, handed to `body` in order.
    ///
    /// Both guards are loud rather than quiet on purpose: a server repeating a token it has already
    /// given is disagreeing with itself and would spin forever, and an enumeration past
    /// ``S3Backend/pageLimit`` is refused rather than truncated. A partial listing that looks
    /// complete is the failure that matters — every write, every count and every search result
    /// downstream would be computed over rows that are not all the rows.
    ///
    /// `isCancelled` is asked **before** each request, so a stop costs nothing further rather than
    /// one more billed page. Only the search route passes one: a directory listing is over before
    /// anyone could press a button, and a delete's sweep must not be abandoned halfway.
    ///
    /// Two more seams, both for a search across an account's buckets (PLAN.md §M38 Slice 5), and
    /// both defaulted so the three callers above are unchanged:
    ///
    /// - `firstPage` is a page already fetched, handed to `body` in place of the first request.
    ///   That search asks for the first page itself, because it is the request that learns whether
    ///   the bucket needs another region or path-style addressing (``S3LocationCorrection``), and
    ///   asking for it twice would bill every bucket a page for nothing.
    /// - `wantsMore` is asked after each page, **before** the next request. Answering `false` ends
    ///   the run with ``S3PageRun/stoppedEarly`` rather than throwing: that is a bound the caller
    ///   chose and can say so, where `pageLimit` is a runaway guard and a run past it is refused.
    ///
    /// - Returns: whether the enumeration reached the end of the listing. Only a run that had a
    ///   next page to ask for and was told not to is ``S3PageRun/stoppedEarly``.
    @discardableResult
    func enumeratePages(
        prefix: String,
        delimiter: String?,
        at path: VFSPath,
        firstPage: S3ListingPage? = nil,
        isCancelled: () -> Bool = { false },
        wantsMore: () -> Bool = { true },
        body: (S3ListingPage) throws -> Void
    ) throws -> S3PageRun {
        var token: String?
        var pages = 0
        var handedOver = firstPage

        while true {
            let page: S3ListingPage
            if let given = handedOver {
                page = given
                handedOver = nil
            } else {
                if isCancelled() { throw CancellationError() }
                page = try listPage(
                    prefix: prefix,
                    delimiter: delimiter,
                    continuationToken: token,
                    at: path
                )
            }
            try body(page)
            pages += 1
            guard page.isTruncated, let next = page.nextContinuationToken else { return .exhausted }
            guard next != token else { throw VFSError.io(path: path, code: EIO) }
            guard pages < pageLimit else { throw VFSError.io(path: path, code: EFBIG) }
            guard wantsMore() else { return .stoppedEarly }
            token = next
        }
    }

    /// How an enumeration ended — see ``enumeratePages(prefix:delimiter:at:firstPage:isCancelled:wantsMore:body:)``.
    enum S3PageRun: Equatable {
        /// The server said there was nothing more.
        case exhausted
        /// There was a next page and the caller's `wantsMore` declined it.
        case stoppedEarly
    }

    /// One page. Internal because `stat` asks for a single page directly, from the main file.
    func listPage(
        prefix: String,
        delimiter: String?,
        continuationToken: String?,
        at path: VFSPath
    ) throws -> S3ListingPage {
        let response = try mapping(path) {
            try transport.listObjects(
                prefix: prefix,
                delimiter: delimiter,
                continuationToken: continuationToken
            )
        }
        let body = try succeed(response, at: path)
        guard let page = try? S3ListingParser.parse(body) else {
            // A 2xx whose body is not a `ListBucketResult` — a captive portal, or a proxy that
            // answered for the endpoint. There is nothing to classify, so it is plain I/O.
            throw VFSError.io(path: path, code: EIO)
        }
        return page
    }
}
