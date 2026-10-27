import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Resolve Conflict… (PLAN.md §M34 Slice 5): which file it acts on, the versions read through the
/// app's own git transport from real scratch repositories, the refusals, and what each pane says.
@Suite("Resolve Conflict")
@MainActor
struct ResolveConflictTests {
    private static func text(_ string: String) -> Data {
        Data(string.utf8)
    }

    /// `readConflict` on a thread of its own, as the app runs it.
    private static func read(_ target: ConflictTarget) async -> Result<
        ConflictDocuments,
        ConflictReadFailure
    > {
        await BlockingWork.run { PanelViewController.readConflict(target) }
    }

    private func bothModified() async throws -> ConflictRepository {
        try await ConflictRepository.make(
            base: ["f.txt": Self.text("a\nb\nc\n")],
            ours: ["f.txt": Self.text("a\nours\nc\n")],
            theirs: ["f.txt": Self.text("a\ntheirs\nc\n")]
        )
    }

    private func entry(_ path: String, kind: FileEntry.Kind = .file) -> FileEntry {
        FileEntry(
            path: .local(path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 4,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 5
        )
    }

    private let snapshot = GitStatusSnapshot(
        repositoryRoot: .local("/repo"),
        branch: GitBranch(name: "main"),
        entries: [
            GitStatusEntry(relativePath: "sub/conflicted.txt", indexStatus: "U", worktreeStatus: "U"),
            GitStatusEntry(relativePath: "both-added.txt", indexStatus: "A", worktreeStatus: "A"),
            GitStatusEntry(relativePath: "edited.txt", indexStatus: " ", worktreeStatus: "M")
        ]
    )

    // MARK: - Which file

    @Test(
        "one file whose own badge is U is the target; a folder's roll-up, an edit or two files are not"
    )
    func target() {
        func target(_ entries: [FileEntry]) -> ConflictTarget? {
            PanelViewController.conflictTarget(in: entries, snapshot: snapshot)
        }
        let conflicted = entry("/repo/sub/conflicted.txt")
        #expect(target([conflicted]) == ConflictTarget(
            entry: conflicted,
            repositoryRoot: .local("/repo"),
            relativePath: "sub/conflicted.txt"
        ))
        #expect(target([entry("/repo/both-added.txt")])?.relativePath == "both-added.txt")
        // The folder holding the conflict is badged U too, by roll-up.
        #expect(snapshot.status(for: .local("/repo/sub")) == .conflicted)
        #expect(target([entry("/repo/sub", kind: .directory)]) == nil)
        #expect(target([entry("/repo/edited.txt")]) == nil)
        #expect(target([conflicted, entry("/repo/both-added.txt")]) == nil)
        #expect(target([]) == nil)
        #expect(PanelViewController.conflictTarget(in: [conflicted], snapshot: nil) == nil)
    }

    // MARK: - Reading the versions

    @Test("the shipped transport reads git's three versions and writes nothing in .git")
    func readsThroughTheApp() async throws {
        let repository = try await bothModified()
        defer { repository.cleanup() }
        let before = try repository.gitDirectoryState()
        let documents = try await Self.read(repository.target("f.txt")).get()
        #expect(try repository.gitDirectoryState() == before)
        #expect(documents.operation == .merge)
        #expect(documents.hasBase)
        #expect(documents.base.text(ofFirstLines: 10) == "a\nb\nc\n")
        #expect(documents.yours.text(ofFirstLines: 10) == "a\nours\nc\n")
        #expect(documents.theirs.text(ofFirstLines: 10) == "a\ntheirs\nc\n")
        // Save is checked against the conflicted file in the working tree, markers and all.
        #expect(documents.target.path == repository.file("f.txt"))
        #expect(documents.target.witness != nil)
    }

    @Test("both added: the merge starts from an empty base, named as none")
    func bothAdded() async throws {
        let repository = try await ConflictRepository.make(
            base: ["keep.txt": Self.text("k\n")],
            ours: ["new.txt": Self.text("ours\n")],
            theirs: ["new.txt": Self.text("theirs\n")]
        )
        defer { repository.cleanup() }
        let target = try repository.target("new.txt")
        let documents = try await Self.read(target).get()
        #expect(!documents.hasBase)
        #expect(documents.base.lines.isEmpty)
        let input = PanelViewController.mergeInput(for: target, documents)
        #expect(input.base.detail == "None: both sides added the file")
        let merge = TextMerge(
            base: input.base.document,
            yours: input.yours.document,
            theirs: input.theirs.document
        )
        #expect(merge.openConflictCount == 1)
    }

    @Test("a deletion, a binary file and a resolved file are each refused by name")
    func refusals() async throws {
        let repository = try await ConflictRepository.make(
            base: [
                "du.txt": Self.text("x\n"),
                "b.bin": Data([0, 1, 2, 10]),
                "done.txt": Self.text("d\n")
            ],
            ours: ["du.txt": nil, "b.bin": Data([0, 1, 3, 10]), "done.txt": Self.text("ours\n")],
            theirs: [
                "du.txt": Self.text("theirs\n"),
                "b.bin": Data([0, 1, 4, 10]),
                "done.txt": Self.text("theirs\n")
            ]
        )
        defer { repository.cleanup() }
        func failure(_ name: String) async throws -> ConflictReadFailure? {
            if case let .failure(failure) = try await Self.read(
                repository.target(name)
            ) {
                return failure
            }
            return nil
        }
        let deleted = try #require(try await failure("du.txt"))
        #expect(deleted == .git(.refused(.deletedByUs)))
        #expect(
            PanelViewController.resolveFailureDetail(deleted).hasPrefix("One side deleted the file")
        )

        let binary = try #require(try await failure("b.bin"))
        #expect(binary == .text(CompareReadFailure(name: "b.bin", reason: .binary)))

        // Staged in a terminal since the badge was drawn.
        try repository.git("add", "done.txt")
        let resolved = try #require(try await failure("done.txt"))
        #expect(resolved == .git(.refused(.notConflicted)))
        #expect(
            PanelViewController.resolveFailureDetail(resolved).hasPrefix(
                "git no longer lists a conflict"
            )
        )
    }

    @Test("the shipped transport hands back git's exit status and its own words on a failure")
    func transportFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-no-repository-\(UUID().uuidString)").path
        #expect {
            try GitProcessTransport().run(GitCommand.gitDirectory(repositoryRoot: missing))
        } throws: { error in
            guard let failure = error as? GitRunFailure else { return false }
            return failure.status == 128 && failure.message.hasPrefix("fatal: cannot change to")
        }
    }

    @Test("git's own words reach the alert when it fails")
    func gitFailure() {
        let said = ConflictReadFailure.git(
            .gitFailed(GitRunFailure(status: 128, message: "fatal: bad object"))
        )
        #expect(
            PanelViewController.resolveFailureDetail(said).hasSuffix("It said: fatal: bad object")
        )
        let silent = ConflictReadFailure.git(.gitFailed(GitRunFailure(status: nil, message: "")))
        #expect(
            PanelViewController.resolveFailureDetail(silent) == "git couldn’t read the file’s versions."
        )
    }

    // MARK: - The panes

    @Test("each pane says what its version is in the operation in progress")
    func paneWords() async throws {
        let repository = try await bothModified()
        defer { repository.cleanup() }
        let target = try repository.target("f.txt")
        let documents = try await Self.read(target).get()
        func input(_ operation: GitOperation) -> MergeInput {
            PanelViewController.mergeInput(
                for: target,
                ConflictDocuments(
                    operation: operation,
                    base: documents.base,
                    hasBase: true,
                    yours: documents.yours,
                    theirs: documents.theirs,
                    target: documents.target
                )
            )
        }
        let merge = input(.merge)
        #expect(merge.name == "f.txt")
        #expect(merge.base.detail == "The common ancestor")
        #expect(merge.yours.detail == "HEAD, the branch you’re on")
        #expect(merge.theirs.detail == "The branch being merged in")
        #expect(merge.resultDetail == "Saved to the working tree; git add marks it resolved")
        // In a rebase git's ours is the branch being rebased onto, and theirs the user's commit.
        #expect(input(.rebase).yours.detail == "HEAD, the branch being rebased onto")
        #expect(input(.rebase).theirs.detail == "The commit being replayed")
        let theirs = GitOperation.allCases.map { input($0).theirs.detail }
        #expect(Set(theirs).count == GitOperation.allCases.count)
    }
}
