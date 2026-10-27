import Foundation
import Testing

@testable import DirnexCore

@Suite("GitConflict")
struct GitConflictTests {
    // MARK: - The listing

    /// `git ls-files --unmerged -z` in `GitStage.listingFormat`, captured from git 2.54 in a scratch
    /// repository: both sides added `aa.txt`, and both changed a name with a space and an *é*.
    private static let capturedListing = Data(
        """
        100644 9caca34375d152009129baeff72d7b67a0cef75e 2 8\taa.txt\0\
        100644 ea312bdf06da2ddfc64772257c789fb89b4b5455 3 10\taa.txt\0\
        100644 b68fde2a051d9af2fe3ff4c96c0898e5a3212e4d 1 2\tspa ce é.txt\0\
        100644 41a047a598aa100f130e747627de3ef5b9da02ae 2 7\tspa ce é.txt\0\
        100644 c691149ca17ca6b7b5d9071a9bfac241b4a0d9b9 3 9\tspa ce é.txt\0
        """.utf8
    )

    @Test("a captured listing reads as one stage per record")
    func parsesCapturedListing() {
        let stages = GitStage.parse(Self.capturedListing)
        #expect(stages.map(\.number) == [2, 3, 1, 2, 3])
        #expect(
            stages.map(\.path) == [
                "aa.txt",
                "aa.txt",
                "spa ce é.txt",
                "spa ce é.txt",
                "spa ce é.txt"
            ]
        )
        #expect(stages.map(\.byteSize) == [8, 10, 2, 7, 9])
        #expect(stages[0] == GitStage(
            number: 2,
            mode: "100644",
            object: "9caca34375d152009129baeff72d7b67a0cef75e",
            byteSize: 8,
            path: "aa.txt"
        ))
    }

    @Test("a path keeps its spaces and tabs, since only the first tab ends the fields")
    func pathKeepsSeparators() {
        let stages = GitStage.parse(Data("100755 abc 3 4\tdir/with\ttab and space\0".utf8))
        #expect(stages == [GitStage(
            number: 3,
            mode: "100755",
            object: "abc",
            byteSize: 4,
            path: "dir/with\ttab and space"
        )])
    }

    @Test("a record that does not read is skipped, not guessed at")
    func skipsBadRecords() {
        let listing = Data("""
        100644 abc 2 4\tgood.txt\0\
        100644 abc 2\tno-size.txt\0\
        100644 abc 4 4\tstage-four.txt\0\
        100644 abc 2 4 no-tab.txt\0\
        \0
        """.utf8)
        #expect(GitStage.parse(listing).map(\.path) == ["good.txt"])
    }

    @Test("a file is a regular or executable mode, not a link or a submodule")
    func fileModes() {
        func stage(_ mode: String) -> GitStage {
            GitStage(number: 2, mode: mode, object: "abc", byteSize: 1, path: "x")
        }
        #expect(stage("100644").isFile)
        #expect(stage("100755").isFile)
        #expect(!stage("120000").isFile)
        #expect(!stage("160000").isFile)
    }

    // MARK: - Which versions there are

    private func stages(_ numbers: [Int], mode: String = "100644") -> [GitStage] {
        numbers.map { GitStage(number: $0, mode: mode, object: "o\($0)", byteSize: 1, path: "f.txt") }
    }

    private func refusal(_ numbers: [Int]) -> GitConflictRefusal? {
        do {
            _ = try GitConflictStages.choose(from: stages(numbers))
            return nil
        } catch {
            return error
        }
    }

    @Test("both sides changed it: three versions")
    func bothModified() throws {
        let chosen = try GitConflictStages.choose(from: stages([3, 1, 2]))
        #expect(chosen.base?.object == "o1")
        #expect(chosen.ours.object == "o2")
        #expect(chosen.theirs.object == "o3")
    }

    @Test("both sides added it: two versions and no base")
    func bothAdded() throws {
        let chosen = try GitConflictStages.choose(from: stages([2, 3]))
        #expect(chosen.base == nil)
        #expect(chosen.ours.object == "o2")
        #expect(chosen.theirs.object == "o3")
    }

    @Test("every set without both sides is refused by name")
    func refusals() {
        #expect(refusal([1, 3]) == .deletedByUs)
        #expect(refusal([1, 2]) == .deletedByThem)
        #expect(refusal([1]) == .deletedByBoth)
        #expect(refusal([2]) == .addedByUs)
        #expect(refusal([3]) == .addedByThem)
        #expect(refusal([]) == .notConflicted)
    }

    @Test("a link or a submodule on any side is refused")
    func notAFile() {
        // git's own shape for a link both sides changed: a file at the base, links on both sides.
        let link = stages([1]) + stages([2, 3], mode: "120000")
        #expect(throws: GitConflictRefusal.notAFile) { try GitConflictStages.choose(from: link) }
        let submodule = stages([1, 2], mode: "160000") + stages([3])
        #expect(throws: GitConflictRefusal.notAFile) { try GitConflictStages.choose(from: submodule) }
        // An executable file is still a file.
        #expect(throws: Never.self) {
            try GitConflictStages.choose(from: stages([1, 2, 3], mode: "100755"))
        }
    }

    // MARK: - What is in progress

    private func operation(_ names: Set<String>) -> GitOperation {
        GitOperation.inProgress(gitDirectory: "/repo/.git") { path in
            names.contains { "/repo/.git/\($0)" == path }
        }
    }

    @Test("each operation is read off its marker in the git directory")
    func operations() {
        #expect(operation(["MERGE_HEAD", "AUTO_MERGE"]) == .merge)
        #expect(operation(["rebase-merge", "AUTO_MERGE"]) == .rebase)
        #expect(operation(["rebase-apply", "rebase-apply/rebasing"]) == .rebase)
        #expect(operation(["rebase-apply", "rebase-apply/applying"]) == .applyingPatches)
        #expect(operation(["CHERRY_PICK_HEAD"]) == .cherryPick)
        #expect(operation(["REVERT_HEAD"]) == .revert)
        // `git stash pop` leaves only `AUTO_MERGE`, which every operation writes.
        #expect(operation(["AUTO_MERGE"]) == .other)
        #expect(operation([]) == .other)
    }

    @Test("a rebase stopped on a merge commit is still a rebase")
    func rebaseOutranksMerge() {
        #expect(operation(["rebase-merge", "MERGE_HEAD"]) == .rebase)
    }

    // MARK: - The commands

    @Test("the reads keep the index untouched and take the path literally")
    func commands() {
        #expect(GitCommand.unmergedStages(repositoryRoot: "/repo", relativePath: "a[1].txt") == [
            "--no-optional-locks", "--literal-pathspecs", "-C", "/repo", "ls-files", "--unmerged",
            "-z", "--format=%(objectmode) %(objectname) %(stage) %(objectsize)%x09%(path)", "--",
            "a[1].txt"
        ])
        #expect(GitCommand.stageContents(
            repositoryRoot: "/repo",
            relativePath: "sub/f.txt",
            object: "abc"
        ) == [
            "--no-optional-locks", "-C", "/repo", "cat-file", "--filters", "--path=sub/f.txt", "abc"
        ])
        #expect(GitCommand.gitDirectory(repositoryRoot: "/repo") == [
            "--no-optional-locks", "-C", "/repo", "rev-parse", "--absolute-git-dir"
        ])
    }
}
