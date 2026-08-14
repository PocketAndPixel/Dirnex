import Foundation
import Testing

@testable import DirnexCore

/// The bound a remote size walk runs under (PLAN.md §M21 Slice 11).
///
/// Two halves, kept in two suites because they fail for different reasons: *which* budget a backend
/// gets is a policy question the compiler cannot check, and *whether the walk honours it* is a loop
/// that has to stop counting at the right moment.
@Suite("Directory size budget")
struct DirectorySizeBudgetTests {
    @Test("a local walk is unbounded — a readdir is neither billed nor a round trip")
    func localIsUnbounded() {
        #expect(DirectorySizeBudget.forBackend(.local).directoryLimit == nil)
    }

    /// The three connected backends together, rather than one test each: they answer through the
    /// single `isRemoteConnection` predicate, and asserting them separately would pass even if the
    /// budget had been keyed on a list of cases that a fourth backend later missed.
    @Test("every connected remote backend is bounded")
    func remoteIsBounded() {
        let remotes: [VFSBackendID] = [
            .sftp(SFTPLocation(host: "h", username: "u")),
            .ftp(FTPLocation(host: "h", username: "u")),
            .s3(S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")),
            .s3Account(S3Account(host: "h", region: "r", accessKeyID: "k"))
        ]
        for backend in remotes {
            #expect(
                DirectorySizeBudget.forBackend(backend).directoryLimit
                    == DirectorySizeBudget.remote.directoryLimit,
                "\(backend) should carry the remote budget"
            )
        }
    }

    /// An archive lists out of a cached `bsdtar -tvf` of a file already on this disk, so it costs
    /// no round trip and no money — bounding it would refuse an answer for nothing. Stated as a
    /// test because "not remote" is easy to widen by accident.
    @Test("an archive and the virtual listings are unbounded")
    func nonRemoteVirtualsAreUnbounded() {
        let unbounded: [VFSBackendID] = [
            .archive(forArchiveAt: "/tmp/pkg.zip"), .search, .trash, .icloud
        ]
        for backend in unbounded {
            #expect(
                DirectorySizeBudget.forBackend(backend).directoryLimit == nil,
                "\(backend) should be unbounded"
            )
        }
    }

    @Test("allows() stops exactly at the limit, not one past it")
    func allowsBoundary() {
        let budget = DirectorySizeBudget(directoryLimit: 3)
        #expect(budget.allows(directoriesListed: 0))
        #expect(budget.allows(directoriesListed: 2))
        #expect(!budget.allows(directoriesListed: 3))
        #expect(!budget.allows(directoriesListed: 4))
    }

    @Test("an unbounded budget allows any count")
    func unboundedAllowsEverything() {
        #expect(DirectorySizeBudget.unbounded.allows(directoriesListed: 1_000_000))
    }
}

/// The walk honouring the budget. `LocalBackend` over a real temp tree, with the counting wrapper
/// that already exists for the exclusion tests — what is being pinned is *how many directories were
/// listed*, and a request count is the only assertion that can see it.
@Suite("DirectorySizer budget")
struct DirectorySizerBudgetTests {
    /// Ten nested directories, each holding one byte, so a walk of depth *n* has listed exactly *n*
    /// of them. Nesting rather than fanning out makes the count deterministic — the stack pops in a
    /// fixed order and no sibling can be listed "first".
    private func chain(depth: Int) throws -> TempTree {
        let tree = try TempTree()
        var path = ""
        for level in 0..<depth {
            path += (level == 0 ? "" : "/") + "d\(level)"
            try tree.makeDir(path)
            try tree.writeFile("\(path)/f.bin", bytes: 1)
        }
        return tree
    }

    @Test("a walk past its budget throws rather than returning a partial total")
    func exceedingThrows() throws {
        let tree = try chain(depth: 6)
        defer { tree.cleanup() }

        // A partial rendered as the answer is a claim about the folder where the truth is a claim
        // about the question, so there is deliberately no number to check here — only the count of
        // what was spent getting there.
        let error = #expect(throws: DirectorySizeBudgetExceeded.self) {
            try DirectorySizer.size(
                of: tree.vfsPath(),
                using: LocalBackend(),
                budget: DirectorySizeBudget(directoryLimit: 3)
            )
        }
        #expect(error?.directoriesListed == 3)
    }

    /// The half a count-only assertion cannot see: that the limit stops the walk from *making* the
    /// request, rather than making it and then throwing. On a billed backend those are different
    /// numbers, and the one that matters is what was spent.
    @Test("the budget is spent, not overspent — exactly `directoryLimit` listings are made")
    func doesNotOverspend() throws {
        let tree = try chain(depth: 6)
        defer { tree.cleanup() }
        let counting = CountingLocalBackend()

        #expect(throws: DirectorySizeBudgetExceeded.self) {
            try DirectorySizer.size(
                of: tree.vfsPath(),
                using: counting,
                budget: DirectorySizeBudget(directoryLimit: 3)
            )
        }
        #expect(counting.listed.count == 3)
    }

    @Test("a budget the tree fits inside completes normally")
    func withinBudgetCompletes() throws {
        let tree = try chain(depth: 3)
        defer { tree.cleanup() }

        // Four listings for three nested directories: the root the walk was pointed at, plus each
        // level below it. A budget equal to that must not give up on the last one.
        let total = try DirectorySizer.size(
            of: tree.vfsPath(),
            using: LocalBackend(),
            budget: DirectorySizeBudget(directoryLimit: 4)
        )
        #expect(total == 3)
    }

    /// The default is what every pre-existing caller gets, so this is the assertion that says the
    /// parameter changed nobody: the same tree, walked with no budget named, still totals.
    @Test("the default budget is unbounded")
    func defaultIsUnbounded() throws {
        let tree = try chain(depth: 12)
        defer { tree.cleanup() }

        #expect(try DirectorySizer.size(of: tree.vfsPath(), using: LocalBackend()) == 12)
    }

    /// Cancellation is checked before the budget, and both mean "no total" — but a caller wording a
    /// message needs to know which happened, so the two must not be collapsible.
    @Test("cancellation outranks the budget")
    func cancellationOutranksBudget() throws {
        let tree = try chain(depth: 6)
        defer { tree.cleanup() }

        #expect(throws: CancellationError.self) {
            try DirectorySizer.size(
                of: tree.vfsPath(),
                using: LocalBackend(),
                budget: DirectorySizeBudget(directoryLimit: 1),
                isCancelled: { true }
            )
        }
    }
}

/// `LocalBackend` that records every directory it was asked to list. A second copy of the one in
/// `DirectorySizerTests`, which is `private` to that file — Swift's `private` does not cross files
/// (docs/NOTES.md ▸ file splitting), and widening it would export a test helper from a suite that
/// does not own this question.
private final class CountingLocalBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let lock = NSLock()
    private var listedPaths: [VFSPath] = []

    var listed: [VFSPath] {
        lock.lock()
        defer { lock.unlock() }
        return listedPaths
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        listedPaths.append(path)
        lock.unlock()
        return try inner.listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
}
