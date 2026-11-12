import AppKit
import DirnexCore

/// ⌥F7 on an S3 account pane: every bucket the key can see, each up to a bound the dialog states
/// before the search starts (PLAN.md §M38 Slice 5).
///
/// Everything about *what* is searched and *when to stop* is the tested `S3AccountSearch`. What is
/// here is the part that needs the app: the sentence the dialog shows, the live account's credential,
/// the connections a hit needs before it can be opened, and what to say about a bucket the search
/// could not finish.
extension PanelViewController {
    /// What the dialog says before an account search starts: the bound, per bucket.
    ///
    /// No bucket count beside it, though the pane is usually showing them: an edit reopens this
    /// dialog from a results tab, whose rows are hits, and a count read from the pane would say
    /// "none" there. The bound is the promise; the buckets are the ones the account lists.
    static var accountSearchBound: String {
        let objects = S3AccountSearch.objectsPerBucket.formatted()
        return String(
            localized: """
            Searches the first \(objects) objects of each bucket, in the order S3 lists them.
            """,
            comment: """
            Find Files note on an S3 account, stated before the search starts. %@ is how many \
            objects of each bucket are looked at, a formatted number such as 10,000.
            """
        )
    }

    /// Open Find Files on `query` for the account at `root`, and run what the user confirms there —
    /// how a search on this route starts when nothing typed it, so the bound is still said first.
    func confirmAccountSearch(_ query: FileQuery, in root: VFSPath, landing: SearchLanding) {
        let controller = makeSearchController(searching: root)
        controller.open(on: query, everything: false)
        controller.onSearch = { [weak self] query, _ in
            self?.runSearch(
                query,
                in: SearchPlace(folder: root, everything: false),
                landing: landing
            )
        }
        presentAsMovableWindow(controller)
    }

    /// Search every bucket of the account at `root` for `query`, with the progress sheet and Stop,
    /// then land the hits where `landing` says, as every other route does.
    func performAccountSearch(_ query: FileQuery, in root: VFSPath, landing: SearchLanding) {
        let predicate: SearchPredicate
        do {
            predicate = try SearchPredicate(
                query,
                answering: SearchFields.answerable(by: root.backend)
            )
        } catch let unanswerable as SearchQueryUnanswerable {
            presentUnanswerable(unanswerable, at: root)
            return
        } catch {
            return
        }
        guard let composite = backend as? CompositeBackend,
              let source = composite.s3AccountSearchSource(for: root.backend)
        else {
            presentOperationFailure(
                message: Self.accountSearchFailureTitle(root),
                detail: VFSErrorText.sentence(
                    for: VFSError.unsupported(.serverNotConnected(server: root.displayName))
                )
            )
            return
        }

        let control = SearchControl()
        let sheet = SearchProgressSheet(
            scopeName: root.displayName,
            control: control,
            window: view.window
        )
        sheet.start()
        Task {
            defer { sheet.finish() }
            do {
                let results = try await S3AccountSearchRunner.run(
                    predicate,
                    in: source.account,
                    secretAccessKey: source.secret,
                    control: control
                )
                sheet.finish()
                adoptBucketConnections(results.connections, secretAccessKey: source.secret)
                landSearchResults(
                    results.hits,
                    truncated: results.completion == .truncated,
                    query: query,
                    scope: root,
                    landing: landing
                )
                reportAccountSearch(results)
            } catch {
                sheet.finish()
                presentOperationFailure(
                    message: Self.accountSearchFailureTitle(root),
                    detail: VFSErrorText.sentence(for: error)
                )
            }
        }
    }

    /// Register a connection for every bucket a hit lives in, so the hit can be opened, copied and
    /// previewed — the rows carry paths on those buckets, and the router knows nothing of a bucket
    /// nobody connected to.
    ///
    /// Each one is registered as entering the bucket would register it, the secret filed for it
    /// included: a hit's folder can be opened into a tab, and a tab on a bucket is restored after a
    /// relaunch from that bucket's own Keychain item (`PanelViewController+Reconnect`).
    func adoptBucketConnections(_ locations: [S3Location], secretAccessKey: String) {
        guard let composite = backend as? CompositeBackend else { return }
        for location in locations {
            composite.connectS3(location: location, secretAccessKey: secretAccessKey)
            SecretKeychain.store(password: secretAccessKey, for: location)
        }
    }

    /// Say how the search ended when that is worth saying.
    ///
    /// A stop and the result limit say what they always say. A search that visited every bucket says
    /// nothing more unless the bound cut a bucket short or a bucket refused, and then names them —
    /// the one thing the result cannot show, since a bucket with no rows in it looks the same whether
    /// nothing matched or nothing was looked at.
    private func reportAccountSearch(_ results: S3AccountSearch.Results) {
        switch results.completion {
        case .stopped:
            reportSearchEnding(.stopped, hits: results.hits.count, listed: 0)
        case .truncated, .budgetExceeded:
            break // `landSearchResults` raised the truncation alert; no budget is shared here
        case .complete:
            guard let detail = Self.unfinishedBuckets(results) else { return }
            presentOperationFailure(
                message: String(
                    localized: "Not every bucket was searched in full",
                    comment: "Title after a search across an S3 account that cut buckets short."
                ),
                detail: detail
            )
        }
    }

    /// The alert's body: which buckets the bound cut short, and which could not be searched and why,
    /// or `nil` when every bucket was searched whole. Static and pure, so a test can read it.
    static func unfinishedBuckets(_ results: S3AccountSearch.Results) -> String? {
        var paragraphs: [String] = []
        if !results.stoppedShort.isEmpty {
            let names = ListFormatter.localizedString(byJoining: results.stoppedShort)
            let objects = S3AccountSearch.objectsPerBucket.formatted()
            paragraphs.append(String(
                localized: """
                Only the first \(objects) objects were searched in \(names). Search inside a bucket \
                to cover all of it.
                """,
                comment: """
                Body after a search across an S3 account. %1$@ is how many objects of each bucket \
                were looked at (a formatted number), %2$@ the buckets that hold more, as a list.
                """
            ))
        }
        // Grouped by reason, since one key is usually refused by every bucket that refuses it for
        // the same reason, and a sentence per bucket would repeat it.
        var reasons: [(sentence: String, names: [String])] = []
        for report in results.failed {
            guard case let .failed(error) = report.outcome else { continue }
            let sentence = VFSErrorText.sentence(for: error)
            if let index = reasons.firstIndex(where: { $0.sentence == sentence }) {
                reasons[index].names.append(report.name)
            } else {
                reasons.append((sentence, [report.name]))
            }
        }
        for reason in reasons {
            let names = ListFormatter.localizedString(byJoining: reason.names)
            paragraphs.append(String(
                localized: "Couldn’t search \(names). \(reason.sentence)",
                comment: """
                Body after a search across an S3 account. %1$@ is the buckets that could not be \
                searched, as a list; %2$@ the reason, a whole sentence.
                """
            ))
        }
        return paragraphs.isEmpty ? nil : paragraphs.joined(separator: "\n\n")
    }

    private static func accountSearchFailureTitle(_ root: VFSPath) -> String {
        String(
            localized: "Couldn’t search “\(root.displayName)”",
            comment: "Search failure title; %@ is the folder or server searched."
        )
    }
}

/// Runs an ``S3AccountSearch`` off the main thread, signing each bucket's requests with the
/// account's own credential — the sibling of `SubtreeSearchRunner`.
enum S3AccountSearchRunner {
    static func run(
        _ predicate: SearchPredicate,
        in account: S3AccountBackend,
        secretAccessKey: String,
        limit: Int = SpotlightSearchRunner.resultLimit,
        control: SearchControl
    ) async throws -> S3AccountSearch.Results {
        try await BlockingWork.run {
            Result {
                try S3AccountSearch.find(
                    in: account,
                    transport: { S3CurlTransport(location: $0, secretAccessKey: secretAccessKey) },
                    matching: predicate,
                    limit: limit,
                    isCancelled: { control.isStopped },
                    onProgress: { control.report($0) }
                )
            }
        }.get()
    }
}
