import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌥F7 on an S3 account pane, in the app (PLAN.md §M38 Slice 5): the bound the dialog states before
/// the search starts, what is said afterwards about a bucket it did not finish, and the connections
/// a hit needs before it can be opened.
///
/// The search itself is `S3AccountSearch`, tested in the core against fake buckets. What is here is
/// the half that can go wrong only in the app: a dialog that opens without its bound, an edit that
/// loses it, a Save Search that would re-run it without it, and hits on buckets nobody connected to.
@MainActor
@Suite("S3 account search in the pane")
struct S3AccountSearchPaneTests {
    private static let account = S3Account(
        host: "s3.eu-central-1.amazonaws.com",
        region: "eu-central-1",
        accessKeyID: "AKIAEXAMPLE"
    )

    private static var accountRoot: VFSPath { VFSPath(backend: .s3Account(account), path: "/") }

    private static func pane(at path: VFSPath, entries: [FileEntry] = []) -> PanelViewController {
        let composite = CompositeBackend(local: LocalBackend())
        // Registering a connection touches no network (`CompositeBackendTests`).
        composite.connectS3Account(account: account, secretAccessKey: "s3cr3t")
        let pane = PanelViewController(
            backend: composite,
            restoration: nil,
            defaultPath: path,
            restorationKey: nil
        )
        pane.panel = Panel(
            model: DirectoryModel(listing: DirectoryListing(path: path, entries: entries))
        )
        return pane
    }

    /// Every label in `view`'s tree, and whether the scope popup's grid row is hidden.
    private static func dialog(_ controller: SearchController) -> (
        labels: [String],
        scopeHidden: Bool?
    ) {
        controller.loadViewIfNeeded()
        var labels: [String] = []
        var scopeHidden: Bool?
        var stack: [NSView] = [controller.view]
        while let view = stack.popLast() {
            if let field = view as? NSTextField, !field.isEditable { labels.append(field.stringValue) }
            if let grid = view as? NSGridView {
                scopeHidden = grid.row(at: grid.numberOfRows - 1).isHidden
            }
            stack += view.subviews
        }
        return (labels, scopeHidden)
    }

    // MARK: - The dialog

    @Test("on an account the dialog states its bound and offers no scope choice")
    func accountDialogStatesTheBound() {
        let pane = Self.pane(at: Self.accountRoot)
        let shown = Self.dialog(pane.makeSearchController(searching: Self.accountRoot))

        #expect(shown.labels.contains(PanelViewController.accountSearchBound))
        #expect(shown.scopeHidden == true)
        #expect(PanelViewController.accountSearchBound.contains(
            S3AccountSearch.objectsPerBucket.formatted()
        ))
    }

    /// The control: inside one bucket a search is a walk, unbounded but for the runaway guard, and
    /// the bound sentence there would be a claim about a search that is not running.
    @Test("inside a bucket the dialog keeps its scope choice and says no bound")
    func bucketDialogIsUnchanged() {
        let bucket = VFSPath(backend: .s3(Self.account.bucketLocation(named: "photos")), path: "/")
        let pane = Self.pane(at: bucket)
        let shown = Self.dialog(pane.makeSearchController(searching: bucket))

        #expect(!shown.labels.contains(PanelViewController.accountSearchBound))
        #expect(shown.scopeHidden == false)
    }

    // MARK: - A results tab

    private static func resultsPane(scope: VFSPath) -> PanelViewController {
        let query = FileQuery(nameContains: "report")
        let path = VFSPath(backend: .search, path: "/" + LocalizedCatalog.summary(of: query))
        let pane = Self.pane(at: path)
        let tab = pane.tabs[pane.activeTabIndex]
        tab.hasLoaded = true
        tab.searchQuery = query
        tab.searchScope = scope
        return pane
    }

    /// The edit reopens the dialog, which is the one place the bound is said — so an account search
    /// can be changed and run again, where saving it could not.
    @Test("editing an account search reopens the dialog with its bound")
    func editKeepsTheBound() throws {
        let pane = Self.resultsPane(scope: Self.accountRoot)
        let controller = try #require(pane.makeEditSearchController())
        let shown = Self.dialog(controller)

        #expect(shown.labels.contains(PanelViewController.accountSearchBound))
        #expect(controller.currentQuery() == FileQuery(nameContains: "report"))
    }

    /// A sidebar re-run starts at once, with no dialog to state the bound (Oleg's call, 2026-11-10).
    @Test("an account search cannot be saved, a bucket search can")
    func accountSearchIsNotSavable() {
        #expect(!Self.resultsPane(scope: Self.accountRoot).canSaveCurrentSearch)
        let bucket = VFSPath(backend: .s3(Self.account.bucketLocation(named: "photos")), path: "/")
        #expect(Self.resultsPane(scope: bucket).canSaveCurrentSearch)
    }

    // MARK: - The connection behind it

    /// From the live connection, so a search raises no Keychain prompt.
    @Test("the search signs with the live account's own secret")
    func usesTheLiveSecret() throws {
        let pane = Self.pane(at: Self.accountRoot)
        let composite = try #require(pane.backend as? CompositeBackend)

        #expect(composite.s3AccountSearchSource(for: .s3Account(Self.account))?.secret == "s3cr3t")
        let other = S3Account(
            host: "s3.us-east-1.amazonaws.com",
            region: "us-east-1",
            accessKeyID: "OTHER"
        )
        #expect(composite.s3AccountSearchSource(for: .s3Account(other)) == nil)
    }

    /// A hit's path is on its bucket, and the router knows nothing of a bucket nobody connected to —
    /// F5, Quick View and Return on a hit all go through it. The secret is filed as entering the
    /// bucket files it, so a tab opened from a hit comes back after a relaunch.
    @Test("the buckets the hits live in are connected, and their secret filed")
    func adoptsTheBucketsWithHits() throws {
        let pane = Self.pane(at: Self.accountRoot)
        let composite = try #require(pane.backend as? CompositeBackend)
        let west = Self.account.bucketLocation(named: "west").movingRegion(to: "us-west-2")
        #expect(!composite.isConnected(.s3(west)))

        pane.adoptBucketConnections([west], secretAccessKey: "s3cr3t")

        #expect(composite.isConnected(.s3(west)))
        #expect(SecretKeychain.password(for: west) == "s3cr3t")
        SecretKeychain.removePassword(for: west)
    }

    // MARK: - What is said afterwards

    private static func report(
        _ name: String,
        _ outcome: S3AccountSearch.BucketOutcome
    ) -> S3AccountSearch.BucketReport {
        S3AccountSearch.BucketReport(name: name, outcome: outcome, location: nil, hits: 0)
    }

    @Test("a search that searched every bucket whole says nothing more")
    func wholeSearchSaysNothing() {
        let results = S3AccountSearch.Results(
            hits: [],
            buckets: [Self.report("a", .complete), Self.report("b", .complete)],
            completion: .complete
        )
        #expect(PanelViewController.unfinishedBuckets(results) == nil)
    }

    /// The one thing a result cannot show: a bucket with no rows looks the same whether nothing
    /// matched or nothing was looked at.
    @Test("buckets cut short and buckets refused are named, refusals grouped by reason")
    func namesUnfinishedBuckets() throws {
        let denied = VFSError.unsupported(.s3ActionNotPermitted(action: .listBucket))
        let broken = VFSError.io(path: Self.accountRoot, code: EIO)
        let results = S3AccountSearch.Results(
            hits: [],
            buckets: [
                Self.report("big", .stoppedShort),
                Self.report("locked", .failed(denied)),
                Self.report("huge", .stoppedShort),
                Self.report("private", .failed(denied)),
                Self.report("gone", .failed(broken)),
                Self.report("fine", .complete)
            ],
            completion: .complete
        )
        let text = try #require(PanelViewController.unfinishedBuckets(results))
        let paragraphs = text.components(separatedBy: "\n\n")

        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].contains(ListFormatter.localizedString(byJoining: ["big", "huge"])))
        #expect(
            paragraphs[1].contains(ListFormatter.localizedString(byJoining: ["locked", "private"]))
        )
        #expect(paragraphs[1].contains(VFSErrorText.sentence(for: denied)))
        #expect(paragraphs[2].contains("gone"))
        #expect(!text.contains("fine"))
    }

    @Test("the progress line counts buckets out of the account's total")
    func progressCountsBuckets() {
        let line = SearchProgressSheet.describe(.buckets(S3AccountSearch.Progress(
            bucketsSearched: 2,
            bucketCount: 5,
            hits: 7,
            currentBucket: "photos"
        )))
        // Read for its numbers, in order, so it holds under any language the test host is pinned to.
        let numbers = line.split { !$0.isNumber }.map(String.init)
        #expect(numbers == ["2", "5", "7"])
        #expect(
            line != SearchProgressSheet.describe(
                .walk(SubtreeSearch.Progress(directoriesListed: 2, hits: 7))
            )
        )
    }
}
