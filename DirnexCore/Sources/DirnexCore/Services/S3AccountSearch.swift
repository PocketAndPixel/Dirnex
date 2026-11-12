import Foundation

/// ⌥F7 on an S3 **account** pane: one search across every bucket the key can see (PLAN.md §M38
/// Slice 5).
///
/// M22 refused this, because the rows are buckets and "search every bucket" is a far more expensive
/// question than the one ⌥F7 asks. What answers that is a bound the user is told before anything is
/// asked: the first ``objectsPerBucket`` objects of **each** bucket, in the order S3 lists keys.
///
/// **A bound per bucket rather than one for the account**, because the buckets come in name order
/// and a shared allowance would let one large bucket early in the alphabet spend it all, leaving
/// every later bucket unsearched under a result that names none of them. Per bucket, every bucket is
/// searched, the cost is known before the search starts (buckets × the bound), and the buckets the
/// bound cut short can be named afterwards — which is what the user needs to know where to look
/// next: inside that bucket, where ⌥F7 searches all of it.
///
/// **One bucket at a time**, for the reasons docs/NOTES.md ▸ Walks gives a bounded set: an allowance
/// is only exact when nothing spends it concurrently, and a stop lands within one request.
///
/// **A bucket that cannot be searched does not end the search.** A key that may list buckets need
/// not be allowed into each of them, and a bucket may sit behind an endpoint that does not answer;
/// the matches in every other bucket are still real answers. It is reported by name with its reason,
/// as the walk skips an unreadable subfolder — except that a bucket is a place the user can see in
/// the pane they searched from, so its absence is said rather than left silent.
///
/// Each bucket is reached the way entering it reaches it: the first page is the probe, and a bucket
/// in another region or one label too deep for the endpoint's certificate is re-aimed by
/// ``S3LocationCorrection``, once each. The location it settles on is reported, because a hit's path
/// carries it and the app has to register that connection before the hit can be opened or copied.
public enum S3AccountSearch {
    /// How many objects of each bucket a search looks at — stated in the Find Files dialog before
    /// the search starts. Ten pages of S3's 1000 keys, about 6 s a bucket at the 0.62 s per page
    /// measured on the slowest endpoint this project has used (``DirectorySizeBudget``), and a
    /// policy rather than a fact about the protocol, which is why it is named here.
    public static let objectsPerBucket = 10000

    /// How far a search has got, published as it moves so the sheet can show a count that moves.
    public struct Progress: Sendable, Equatable {
        /// Buckets finished, whatever their outcome.
        public let bucketsSearched: Int
        public let bucketCount: Int
        public let hits: Int
        /// The bucket being searched now, `nil` before the first and after the last.
        public let currentBucket: String?

        public init(bucketsSearched: Int, bucketCount: Int, hits: Int, currentBucket: String?) {
            self.bucketsSearched = bucketsSearched
            self.bucketCount = bucketCount
            self.hits = hits
            self.currentBucket = currentBucket
        }
    }

    /// What became of one bucket.
    public enum BucketOutcome: Sendable, Equatable {
        /// Every object in it was looked at.
        case complete
        /// The bound was reached with objects left over. The one outcome the user is told about by
        /// name after a search that finished, since only searching inside the bucket covers the rest.
        case stoppedShort
        /// It could not be listed, for this reason. Also told by name.
        case failed(VFSError)
        /// The search ended while in this bucket — Stop, or the result limit — so some of it was
        /// looked at and nothing is claimed about the rest. The hits found in it are kept.
        case interrupted
        /// The search ended before this bucket was reached.
        case notSearched
    }

    public struct BucketReport: Sendable, Equatable {
        public let name: String
        public let outcome: BucketOutcome
        /// The connection the bucket answered at — its listed region, or the one a redirect named,
        /// and path-style when the certificate needed it. `nil` when it was never reached.
        public let location: S3Location?
        /// How many of the search's hits came from this bucket.
        public let hits: Int

        public init(name: String, outcome: BucketOutcome, location: S3Location?, hits: Int) {
            self.name = name
            self.outcome = outcome
            self.location = location
            self.hits = hits
        }
    }

    public struct Results: Sendable, Equatable {
        /// Every match, bucket by bucket in the order the account lists them.
        public let hits: [FileEntry]
        /// One report per bucket the account listed, in the same order.
        public let buckets: [BucketReport]
        /// How the search ended. ``SubtreeSearch/Completion/complete`` means every bucket was
        /// visited, which is not the same as every object: the buckets the bound cut short are in
        /// ``stoppedShort``. ``SubtreeSearch/Completion/budgetExceeded`` is never answered here, since
        /// the bound is per bucket and is reported per bucket.
        public let completion: SubtreeSearch.Completion

        public init(hits: [FileEntry], buckets: [BucketReport], completion: SubtreeSearch.Completion) {
            self.hits = hits
            self.buckets = buckets
            self.completion = completion
        }

        /// The buckets the bound cut short, by name.
        public var stoppedShort: [String] {
            buckets.filter { $0.outcome == .stoppedShort }.map(\.name)
        }

        /// The buckets that could not be listed, with why.
        public var failed: [BucketReport] {
            buckets.filter {
                if case .failed = $0.outcome { return true }
                return false
            }
        }

        /// The connections the hits live on — what the app registers so a hit can be opened.
        public var connections: [S3Location] {
            buckets.compactMap { $0.hits > 0 ? $0.location : nil }
        }
    }

    /// Search every bucket `account` lists for whatever `predicate` accepts.
    ///
    /// - Parameters:
    ///   - transport: the connection to one bucket, built for each location tried. Called again
    ///     for a re-aimed location, so the request is signed for where it now goes.
    ///   - limit: the most hits to gather — the app's rendering cap, as on a walk.
    ///   - isCancelled: asked before every request. Answering `true` ends the search with
    ///     ``SubtreeSearch/Completion/stopped`` and every hit found so far, the current bucket's
    ///     included — see ``SubtreeSearch/Completion/stopped`` for why a stop returns.
    ///
    /// - Throws: whatever listing the account's buckets throws. That is the scope itself, so a
    ///   failure there means there is no search rather than a gap in one — `SubtreeSearch`'s rule for
    ///   its root. A bucket that fails is a ``BucketOutcome/failed(_:)`` and never throws.
    public static func find(
        in account: S3AccountBackend,
        transport: (S3Location) -> any S3Transport,
        matching predicate: SearchPredicate,
        objectsPerBucket: Int = objectsPerBucket,
        limit: Int = .max,
        isCancelled: () -> Bool = { false },
        onProgress: (Progress) -> Void = { _ in }
    ) throws -> Results {
        guard !isCancelled() else { return Results(hits: [], buckets: [], completion: .stopped) }
        let buckets = try account.buckets()
        let question = Question(
            account: account.account,
            predicate: predicate,
            objectLimit: objectsPerBucket
        )
        var run = Run(bucketCount: buckets.count, limit: limit)
        onProgress(run.progress(current: nil))

        for bucket in buckets {
            guard run.completion == nil else {
                run.skip(bucket)
                continue
            }
            onProgress(run.progress(current: bucket.name))
            search(
                bucket,
                asking: question,
                into: &run,
                transport: transport,
                isCancelled: isCancelled
            )
            onProgress(run.progress(current: nil))
        }
        return run.results
    }

    // MARK: - One bucket

    /// What every bucket of one search is asked: where the account is, what matches, and how far
    /// to look.
    private struct Question {
        let account: S3Account
        let predicate: SearchPredicate
        let objectLimit: Int
    }

    private static func search(
        _ bucket: S3Bucket,
        asking question: Question,
        into run: inout Run,
        transport: (S3Location) -> any S3Transport,
        isCancelled: () -> Bool
    ) {
        let objectLimit = question.objectLimit
        let reached: (location: S3Location, firstPage: S3ListingPage)
        switch reach(bucket, of: question.account, transport: transport, isCancelled: isCancelled) {
        case .stopped:
            run.stop(in: bucket)
            return
        case let .failed(error, location):
            run.record(bucket, .failed(error), at: location, matches: [])
            return
        case let .reached(location, firstPage):
            reached = (location, firstPage)
        }

        let backend = S3Backend(location: reached.location, transport: transport(reached.location))
        let root = VFSPath(backend: .s3(reached.location), path: "/")
        let listing: VFSSubtreeListing
        do {
            listing = try backend.boundedSubtreeListing(
                at: root,
                objectLimit: objectLimit,
                firstPage: reached.firstPage,
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            run.stop(in: bucket, at: reached.location)
            return
        } catch let error as VFSError {
            run.record(bucket, .failed(error), at: reached.location, matches: [])
            return
        } catch {
            let failure = VFSError.io(path: root, code: EIO)
            run.record(bucket, .failed(failure), at: reached.location, matches: [])
            return
        }

        let matches = listing.entries.filter(question.predicate.matches)
        if listing.isComplete {
            run.record(bucket, .complete, at: reached.location, matches: matches)
        } else if isCancelled() {
            run.record(bucket, .interrupted, at: reached.location, matches: matches)
            run.end(.stopped)
        } else {
            run.record(bucket, .stoppedShort, at: reached.location, matches: matches)
        }
    }
}

// MARK: - Reaching a bucket

extension S3AccountSearch {
    /// How reaching a bucket's first page came out.
    enum Reach: Equatable {
        case reached(S3Location, firstPage: S3ListingPage)
        case failed(VFSError, S3Location)
        case stopped
    }

    /// Ask for the first page of `bucket`'s flat listing, re-aiming at most once for a region and
    /// once for the addressing — the two corrections a connect makes, by the same rules.
    ///
    /// The first page doubles as the probe, which is what entering a bucket spends a request on
    /// separately; a search that probed and then listed would bill every bucket an extra page.
    static func reach(
        _ bucket: S3Bucket,
        of account: S3Account,
        transport: (S3Location) -> any S3Transport,
        isCancelled: () -> Bool
    ) -> Reach {
        var location = startingLocation(for: bucket, of: account)
        var regionCorrected = false
        var addressingCorrected = false

        while true {
            if isCancelled() { return .stopped }
            let root = VFSPath(backend: .s3(location), path: "/")
            let response: S3Response
            do {
                response = try transport(location).listObjects(
                    prefix: S3Key.listingPrefix(for: root),
                    delimiter: nil,
                    continuationToken: nil
                )
            } catch {
                if !addressingCorrected,
                   let next = S3LocationCorrection.afterTransportFailure(error, at: location) {
                    location = next
                    addressingCorrected = true
                    continue
                }
                return .failed(.io(path: root, code: EIO), location)
            }
            if let service = S3Backend.serviceError(from: response) {
                if !regionCorrected,
                   let next = S3LocationCorrection.afterRefusal(service, at: location) {
                    location = next
                    regionCorrected = true
                    continue
                }
                return .failed(service.vfsError(for: root, action: .listBucket), location)
            }
            guard let page = try? S3ListingParser.parse(response.body) else {
                // A 2xx that is not a listing: a captive portal, or a proxy answering for the
                // endpoint. Nothing to classify, so plain I/O, as the backend reads it.
                return .failed(.io(path: root, code: EIO), location)
            }
            return .reached(location, firstPage: page)
        }
    }

    /// Where to ask first: the account's endpoint, in the region the bucket list named for this
    /// bucket when it named one. AWS has listed a region per bucket since 2024; an S3-compatible
    /// server usually does not, and then the account's own region is tried and a 301 corrects it.
    static func startingLocation(for bucket: S3Bucket, of account: S3Account) -> S3Location {
        let location = account.bucketLocation(named: bucket.name)
        guard let region = bucket.region, !region.isEmpty, region != location.region else {
            return location
        }
        return location.movingRegion(to: region)
    }

    // MARK: - Book-keeping

    /// What a search has gathered so far, and whether it has ended.
    private struct Run {
        let bucketCount: Int
        let limit: Int
        var hits: [FileEntry] = []
        var reports: [BucketReport] = []
        /// Set once the search has ended — every later bucket is ``BucketOutcome/notSearched``.
        var completion: SubtreeSearch.Completion?

        init(bucketCount: Int, limit: Int) {
            self.bucketCount = bucketCount
            self.limit = limit
        }

        var results: Results {
            Results(hits: hits, buckets: reports, completion: completion ?? .complete)
        }

        func progress(current: String?) -> Progress {
            Progress(
                bucketsSearched: reports.count,
                bucketCount: bucketCount,
                hits: hits.count,
                currentBucket: current
            )
        }

        /// File one bucket's matches, cutting at the result limit. A bucket the limit cuts into is
        /// ``BucketOutcome/interrupted`` whatever it would otherwise have been, since the matches
        /// past the cut were found and not kept.
        mutating func record(
            _ bucket: S3Bucket,
            _ outcome: BucketOutcome,
            at location: S3Location?,
            matches: [FileEntry]
        ) {
            let room = max(limit - hits.count, 0)
            let kept = matches.prefix(room)
            hits += kept
            let cut = matches.count > room
            reports.append(BucketReport(
                name: bucket.name,
                outcome: cut ? .interrupted : outcome,
                location: location,
                hits: kept.count
            ))
            if hits.count >= limit, completion == nil { completion = .truncated }
        }

        /// End the search at Stop, in `bucket`. With no `location` nothing of it was listed, so it
        /// was not searched at all; with one, some of it may have been.
        mutating func stop(in bucket: S3Bucket, at location: S3Location? = nil) {
            reports.append(BucketReport(
                name: bucket.name,
                outcome: location == nil ? .notSearched : .interrupted,
                location: location,
                hits: 0
            ))
            end(.stopped)
        }

        mutating func skip(_ bucket: S3Bucket) {
            reports.append(BucketReport(
                name: bucket.name,
                outcome: .notSearched,
                location: nil,
                hits: 0
            ))
        }

        mutating func end(_ how: SubtreeSearch.Completion) {
            if completion == nil { completion = how }
        }
    }
}
