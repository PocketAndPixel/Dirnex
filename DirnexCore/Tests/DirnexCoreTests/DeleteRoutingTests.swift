import Foundation
import Testing

@testable import DirnexCore

/// F8 over rows that need not share a directory: each row's own directory answers, and the weakest
/// answer wins.
@Suite("Delete routing")
struct DeleteRoutingTests {
    private static let results = VFSPath(backend: .search, path: "/Results")
    private static let documents = VFSPath.local("/Users/tester/Documents")
    private static let desktop = VFSPath.local("/Users/tester/Desktop")
    private static let trash = VFSPath.local("/Users/tester/.Trash")
    private static let archive = VFSPath(
        backend: .archive(forArchiveAt: "/tmp/a.zip"),
        path: "/docs"
    )

    /// The answers a `CompositeBackend` gives, reduced to what the rule reads: an ordinary folder
    /// trashes, a Trash deletes only for good, an archive and the synthetic container delete nothing.
    private static func capabilities(_ directory: VFSPath) -> VFSCapabilities {
        if directory == trash { return [.read, .write] }
        if directory.backend == .local { return [.read, .write, .trash, .rename] }
        return .read
    }

    private static func strategy(_ paths: [VFSPath]) -> DeleteStrategy {
        DeleteRouting.strategy(for: paths, paneDirectory: results, capabilities: capabilities)
    }

    /// The reported gap itself: hits in ordinary folders, under a container that can delete nothing.
    @Test("search hits in ordinary folders go to the Trash, whatever the container says")
    func hitsAskTheirOwnFolders() {
        #expect(Self.capabilities(Self.results).deleteStrategy == .unsupported)
        let hits = [Self.documents.appending("a.txt"), Self.desktop.appending("b.txt")]
        #expect(Self.strategy(hits) == .trash)
    }

    @Test("one row that can only be deleted for good makes the whole gesture permanent")
    func permanentIsWeakerThanTrash() {
        let hits = [Self.documents.appending("a.txt"), Self.trash.appending("b.txt")]
        #expect(Self.strategy(hits) == .permanent)
    }

    /// The other direction of the same rule, and the half that keeps a mixed set from deleting the
    /// rows it can while ignoring the one it cannot.
    @Test("one row that cannot be deleted refuses the whole gesture")
    func unsupportedRefusesEverything() {
        let hits = [Self.documents.appending("a.txt"), Self.archive.appending("c.txt")]
        #expect(Self.strategy(hits) == .unsupported)
        #expect(
            Self.strategy([Self.trash.appending("b.txt"), Self.archive.appending("c.txt")]) == .unsupported
        )
    }

    /// What lets a menu validator ask this alone, without a second "is anything selected" clause.
    @Test("nothing to delete is unsupported")
    func emptyIsUnsupported() {
        #expect(Self.strategy([]) == .unsupported)
    }

    /// The narrowness control: in a plain listing the rows' directory *is* the pane's, so the answer
    /// must be exactly what asking the pane gave before.
    @Test("in a plain listing it is the pane's own answer")
    func plainListingIsUnchanged() {
        let rows = [Self.documents.appending("a.txt"), Self.documents.appending("b.txt")]
        let strategy = DeleteRouting.strategy(
            for: rows,
            paneDirectory: Self.documents,
            capabilities: Self.capabilities
        )
        #expect(strategy == Self.capabilities(Self.documents).deleteStrategy)
    }

    /// A validator over thousands of marked hits must not ask the backend thousands of times.
    @Test("each directory is asked once")
    func asksPerDirectory() {
        var asked: [VFSPath] = []
        let rows = (0..<500).map { Self.documents.appending("\($0).txt") }
            + [Self.desktop.appending("x.txt")]
        _ = DeleteRouting.strategy(for: rows, paneDirectory: Self.results) {
            asked.append($0)
            return Self.capabilities($0)
        }
        #expect(asked.count == 2)
    }

    // MARK: - What a pass removed

    private static func path(_ name: String) -> VFSPath { documents.appending(name) }

    /// Every outcome a pass can have, at once: the rows a caller drops are exactly the ones that are
    /// no longer where they were.
    @Test("a pass removed everything that neither failed nor was refused")
    func deletedExcludesFailedAndRefused() {
        let paths = ["a", "denied", "notrash", "b"].map(Self.path)
        let outcome = DeletePass.Outcome(
            failures: [
                OperationItemFailure(
                    path: Self.path("denied"),
                    error: .permissionDenied(Self.path("denied"))
                )
            ],
            restorations: [
                DeletePass.Restoration(original: Self.path("a"), trashed: .local("/.Trash/a"))
            ],
            refused: [Self.path("notrash")]
        )
        #expect(outcome.deleted(from: paths) == [Self.path("a"), Self.path("b")])
    }

    /// The shortcut this guards against: a permanent pass journals no restorations, and a trashed
    /// item whose landing place is unknown is not journaled either — both were still deleted.
    @Test("an item with no recorded Trash location was still deleted")
    func deletedIsNotRestorations() {
        let paths = [Self.path("a"), Self.path("b")]
        #expect(DeletePass.Outcome().deleted(from: paths) == paths)
    }
}
