import Foundation
import Testing

@testable import DirnexCore

/// `GitConflictReader` against real git, in scratch repositories stopped on a conflict
/// (PLAN.md §M34 Slice 5): each kind of unmerged path, the filters a checkout runs, and the
/// repository left exactly as it was.
@Suite("GitConflictReader against git")
struct GitConflictReaderLiveTests {
    /// A repository where `base` was committed, `theirs` changed it on a branch and `ours` on
    /// `main`, and `git merge` then stopped on the conflicts. A `nil` content deletes the file.
    private func merged(
        base: [String: String],
        ours: [String: String?],
        theirs: [String: String?],
        attributes: String? = nil
    ) throws -> GitScratchRepository {
        let repository = try GitScratchRepository()
        if let attributes { try repository.write(".gitattributes", attributes) }
        for (name, contents) in base {
            try repository.write(name, contents)
        }
        try repository.commit("base")
        try repository.git("checkout", "-q", "-b", "theirs")
        try apply(theirs, to: repository)
        try repository.commit("theirs")
        try repository.git("checkout", "-q", "main")
        try apply(ours, to: repository)
        try repository.commit("ours")
        let (status, _) = try repository.run(["merge", "theirs"])
        try #require(status == 1, "the merge was meant to stop on a conflict")
        return repository
    }

    private func apply(_ changes: [String: String?], to repository: GitScratchRepository) throws {
        for (name, contents) in changes {
            if let contents {
                try repository.write(name, contents)
            } else {
                try repository.git("rm", "-q", name)
            }
        }
    }

    private func read(
        _ path: String,
        in repository: GitScratchRepository
    ) throws(GitConflictReader.Failure) -> GitConflictVersions {
        try GitConflictReader.read(
            path,
            inRepositoryAt: repository.root,
            byteLimit: ByteComparator.prescanByteLimit,
            transport: repository.transport,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private func failure(_ path: String, in repository: GitScratchRepository) -> GitConflictReader.Failure? {
        do {
            _ = try read(path, in: repository)
            return nil
        } catch {
            return error
        }
    }

    private func text(_ data: Data?) -> String? {
        data.flatMap { String(bytes: $0, encoding: .utf8) }
    }

    @Test("both modified: the three versions git holds, in a merge")
    func bothModified() throws {
        let repository = try merged(
            base: ["f.txt": "a\nb\nc\n"],
            ours: ["f.txt": "a\nours\nc\n"],
            theirs: ["f.txt": "a\ntheirs\nc\n"]
        )
        defer { repository.cleanup() }
        let versions = try read("f.txt", in: repository)
        #expect(versions.operation == .merge)
        #expect(text(versions.base) == "a\nb\nc\n")
        #expect(text(versions.ours) == "a\nours\nc\n")
        #expect(text(versions.theirs) == "a\ntheirs\nc\n")
    }

    @Test("under eol=crlf each version is what a checkout writes, as the working tree is")
    func checkoutForm() throws {
        let repository = try merged(
            base: ["f.txt": "a\nb\nc\n"],
            ours: ["f.txt": "a\nours\nc\n"],
            theirs: ["f.txt": "a\ntheirs\nc\n"],
            attributes: "*.txt text eol=crlf\n"
        )
        defer { repository.cleanup() }
        let versions = try read("f.txt", in: repository)
        #expect(text(versions.base) == "a\r\nb\r\nc\r\n")
        #expect(text(versions.ours) == "a\r\nours\r\nc\r\n")
        #expect(text(versions.theirs) == "a\r\ntheirs\r\nc\r\n")
        // The control: git's conflicted file in the working tree has CRLF too.
        let working = try String(contentsOfFile: repository.tree.path("f.txt"), encoding: .utf8)
        #expect(working.hasPrefix("a\r\n<<<<<<<"))
    }

    @Test("both added: no base")
    func bothAdded() throws {
        let repository = try merged(
            base: ["keep.txt": "k\n"],
            ours: ["new.txt": "ours\n"],
            theirs: ["new.txt": "theirs\n"]
        )
        defer { repository.cleanup() }
        let versions = try read("new.txt", in: repository)
        #expect(versions.base == nil)
        #expect(text(versions.ours) == "ours\n")
        #expect(text(versions.theirs) == "theirs\n")
    }

    @Test("a deletion on either side is refused by name")
    func deletions() throws {
        let repository = try merged(
            base: ["du.txt": "x\n", "ud.txt": "x\n"],
            ours: ["du.txt": nil, "ud.txt": "ours\n"],
            theirs: ["du.txt": "theirs\n", "ud.txt": nil]
        )
        defer { repository.cleanup() }
        #expect(failure("du.txt", in: repository) == .refused(.deletedByUs))
        #expect(failure("ud.txt", in: repository) == .refused(.deletedByThem))
    }

    @Test("a rename to two names: the old name both deleted, each new one only one side has")
    func renameToTwoNames() throws {
        let contents = "one\ntwo\nthree\n"
        let repository = try merged(
            base: ["f.txt": contents],
            ours: ["f.txt": nil, "g.txt": contents],
            theirs: ["f.txt": nil, "h.txt": contents]
        )
        defer { repository.cleanup() }
        #expect(failure("f.txt", in: repository) == .refused(.deletedByBoth))
        #expect(failure("g.txt", in: repository) == .refused(.addedByUs))
        #expect(failure("h.txt", in: repository) == .refused(.addedByThem))
    }

    @Test("a link both sides changed is refused")
    func link() throws {
        let repository = try GitScratchRepository()
        defer { repository.cleanup() }
        try repository.tree.symlink("link", to: "base")
        try repository.commit("base")
        try repository.git("checkout", "-q", "-b", "theirs")
        try FileManager.default.removeItem(atPath: repository.tree.path("link"))
        try repository.tree.symlink("link", to: "theirs")
        try repository.commit("theirs")
        try repository.git("checkout", "-q", "main")
        try FileManager.default.removeItem(atPath: repository.tree.path("link"))
        try repository.tree.symlink("link", to: "ours")
        try repository.commit("ours")
        try #require(try repository.run(["merge", "theirs"]).status == 1)
        #expect(failure("link", in: repository) == .refused(.notAFile))
    }

    @Test("a name with pattern characters or a leading colon reads only itself")
    func literalPath() throws {
        let repository = try merged(
            base: ["a[1].txt": "base\n", "a1.txt": "other base\n", ":colon.txt": "base\n"],
            ours: ["a[1].txt": "ours\n", "a1.txt": "other ours\n", ":colon.txt": "ours\n"],
            theirs: ["a[1].txt": "theirs\n", "a1.txt": "other theirs\n", ":colon.txt": "theirs\n"]
        )
        defer { repository.cleanup() }
        let versions = try read("a[1].txt", in: repository)
        #expect(text(versions.ours) == "ours\n")
        #expect(text(versions.theirs) == "theirs\n")
        // As a pattern, a leading colon starts git's pathspec magic, and the file is not found.
        #expect(text(try read(":colon.txt", in: repository).theirs) == "theirs\n")
    }

    @Test("a rebase and a cherry-pick are named, and in a rebase ours is the branch rebased onto")
    func operations() throws {
        let rebased = try merged(
            base: ["f.txt": "a\nb\nc\n"],
            ours: ["f.txt": "a\nmain\nc\n"],
            theirs: ["f.txt": "a\nbranch\nc\n"]
        )
        defer { rebased.cleanup() }
        try rebased.git("merge", "--abort")
        try rebased.git("checkout", "-q", "theirs")
        try #require(try rebased.run(["rebase", "main"]).status != 0)
        let versions = try read("f.txt", in: rebased)
        #expect(versions.operation == .rebase)
        #expect(text(versions.ours) == "a\nmain\nc\n")
        #expect(text(versions.theirs) == "a\nbranch\nc\n")

        try rebased.git("rebase", "--abort")
        try rebased.git("checkout", "-q", "main")
        try #require(try rebased.run(["cherry-pick", "theirs"]).status != 0)
        #expect(try read("f.txt", in: rebased).operation == .cherryPick)
    }

    @Test("no read writes anything in the git directory, where a plain status does")
    func readsWriteNothing() throws {
        let repository = try merged(
            base: ["f.txt": "a\nb\nc\n", "clean.txt": "clean\n", "du.txt": "x\n"],
            ours: ["f.txt": "a\nours\nc\n", "new.txt": "ours\n", "du.txt": nil],
            theirs: ["f.txt": "a\ntheirs\nc\n", "new.txt": "theirs\n", "du.txt": "theirs\n"]
        )
        defer { repository.cleanup() }
        // A clean file whose time no longer matches the index's record, which is what makes a
        // status refresh the index.
        try repository.tree.setModificationDate("clean.txt", to: Date(timeIntervalSinceNow: -3600))
        let before = try repository.gitDirectoryState()
        _ = try read("f.txt", in: repository)
        _ = try read("new.txt", in: repository)
        #expect(failure("du.txt", in: repository) == .refused(.deletedByUs))
        #expect(failure("missing.txt", in: repository) == .refused(.notConflicted))
        #expect(try repository.gitDirectoryState() == before)
        // The control: the instrument sees a write when there is one.
        try repository.git("status", "--porcelain")
        #expect(try repository.gitDirectoryState() != before)
    }
}
