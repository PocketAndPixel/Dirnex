import Foundation
import Testing

@testable import DirnexCore

/// ⇧F2 inside a browsed archive: which batches can be carried out in one staged tree, in what order,
/// and that carrying them out moves exactly what was asked.
///
/// The staging tests run against a real scratch directory on this Mac's APFS, because the claims are
/// the filesystem's (a case-only change goes through, an occupied name is refused).
@Suite("ArchiveMutation: renaming a batch")
struct ArchiveMutationRenamingTests {
    private typealias Rename = ArchiveMutation.Rename
    private typealias Move = ArchiveMutation.Move

    // MARK: - The plan

    @Test("each member is renamed in the folder it is in")
    func movesStayInTheirFolders() {
        let moves = ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a.txt", newName: "1.txt"),
            Rename(innerPath: "/docs/b.txt", newName: "2.txt")
        ])
        #expect(moves == [
            Move(from: "/docs/b.txt", to: "/docs/2.txt"),
            Move(from: "/a.txt", to: "/1.txt")
        ])
    }

    /// The order that makes a tree selection work: the file inside the folder moves while the folder
    /// still has its old name, and the folder then carries it. The reverse order would leave the
    /// file's source pointing at nothing.
    @Test("a member inside a renamed folder moves before the folder does")
    func deepestFirst() {
        let moves = ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/docs", newName: "guides"),
            Rename(innerPath: "/docs/api/x.md", newName: "y.md"),
            Rename(innerPath: "/docs/api", newName: "reference")
        ])
        #expect(moves == [
            Move(from: "/docs/api/x.md", to: "/docs/api/y.md"),
            Move(from: "/docs/api", to: "/docs/reference"),
            Move(from: "/docs", to: "/guides")
        ])
    }

    @Test("members at one depth keep the order they came in")
    func stableAtOneDepth() {
        let moves = ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/c", newName: "3"),
            Rename(innerPath: "/a", newName: "1"),
            Rename(innerPath: "/b", newName: "2")
        ])
        #expect(moves?.map(\.from) == ["/c", "/a", "/b"])
    }

    /// A member may take its own name in another case: that is a rename, and the staged move
    /// performs it.
    @Test("a case-only change of a member's own name is allowed")
    func caseOnlyChange() {
        #expect(
            ArchiveMutation.renameMoves(for: [Rename(innerPath: "/Photo.JPG", newName: "photo.jpg")])
                == [Move(from: "/Photo.JPG", to: "/photo.jpg")]
        )
    }

    /// The narrowness control for the duplicate rule: one name in two *different* folders is two
    /// names, so a tree selection can give `a/x` and `b/x` the same new name.
    @Test("one new name in two folders is not a clash")
    func sameNameInTwoFolders() {
        let moves = ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a/one.txt", newName: "same.txt"),
            Rename(innerPath: "/b/two.txt", newName: "same.txt")
        ])
        #expect(moves?.count == 2)
    }

    // MARK: - Batches that cannot be one pass

    @Test("a name no member can have refuses the whole batch")
    func refusesANameThatIsNotAName() {
        for bad in ["", ".", "..", "a/b"] {
            #expect(
                ArchiveMutation.renameMoves(for: [
                    Rename(innerPath: "/fine.txt", newName: "ok.txt"),
                    Rename(innerPath: "/docs/x.md", newName: bad)
                ]) == nil,
                "\(bad) should refuse the batch"
            )
        }
    }

    @Test("two members landing on one name in one folder are refused, whatever the case")
    func refusesTwoOntoOne() {
        #expect(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a.txt", newName: "same.txt"),
            Rename(innerPath: "/b.txt", newName: "SAME.txt")
        ]) == nil)
    }

    /// Both only work in one particular order, and a swap in no order at all without a third name.
    /// The planner reports them as collisions; the writer refuses them too.
    @Test("a swap and a chain are refused")
    func refusesSwapsAndChains() {
        #expect(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a", newName: "b"),
            Rename(innerPath: "/b", newName: "a")
        ]) == nil)
        #expect(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a", newName: "b"),
            Rename(innerPath: "/b", newName: "c")
        ]) == nil)
        #expect(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a", newName: "B"),
            Rename(innerPath: "/b", newName: "c")
        ]) == nil, "a chain differing only in case is still a chain on APFS")
    }

    @Test("the same member named twice is refused")
    func refusesTheSameMemberTwice() {
        #expect(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/a", newName: "b"),
            Rename(innerPath: "/a", newName: "c")
        ]) == nil)
    }

    // MARK: - Staging

    @Test("a batch moves every member, and each keeps its bytes")
    func stagesABatch() throws {
        let tree = try StagedTree()
        let moves = try #require(ArchiveMutation.renameMoves(for: [
            Rename(innerPath: "/readme.txt", newName: "README.md"),
            Rename(innerPath: "/docs", newName: "guides"),
            Rename(innerPath: "/docs/api.md", newName: "reference.md")
        ]))

        try ArchiveMutation.stage(moves, ofArchiveAt: tree.archive, inWorkingDirectory: tree.root)

        #expect(try tree.contents(of: "/") == ["README.md", "guides"])
        #expect(try tree.contents(of: "/guides") == ["reference.md"])
        #expect(try tree.text(of: "/README.md") == "read me")
        #expect(try tree.text(of: "/guides/reference.md") == "api")
    }

    /// The staged move is the guard against a name a member *outside* the batch holds, which the
    /// plan does not see. Refused with the member's own path in the archive.
    @Test("a name held outside the batch is refused, naming the member")
    func refusesANameHeldOutsideTheBatch() throws {
        let tree = try StagedTree()
        let moves = [Move(from: "/docs/api.md", to: "/docs/notes.md")]
        try "notes".write(toFile: tree.root + "/docs/notes.md", atomically: false, encoding: .utf8)

        #expect(throws: VFSError.alreadyExists(tree.member("/docs/notes.md"))) {
            try ArchiveMutation.stage(
                moves,
                ofArchiveAt: tree.archive,
                inWorkingDirectory: tree.root
            )
        }
        #expect(try tree.text(of: "/docs/notes.md") == "notes")
        #expect(try tree.text(of: "/docs/api.md") == "api")
    }

    @Test("a case-only change goes through in the staged tree")
    func stagesACaseOnlyChange() throws {
        let tree = try StagedTree()
        let moves = try #require(
            ArchiveMutation.renameMoves(
                for: [Rename(innerPath: "/readme.txt", newName: "README.txt")]
            )
        )

        try ArchiveMutation.stage(moves, ofArchiveAt: tree.archive, inWorkingDirectory: tree.root)

        #expect(try tree.contents(of: "/").contains("README.txt"))
        #expect(try tree.text(of: "/README.txt") == "read me")
    }

    // MARK: - Fixture

    /// A scratch tree shaped like an extracted archive: `readme.txt` and `docs/api.md`.
    private final class StagedTree {
        let root: String
        let archive = "/Users/tester/fixture.zip"

        init() throws {
            root = NSTemporaryDirectory() + "dirnex-archive-rename-\(UUID().uuidString)"
            try FileManager.default.createDirectory(
                atPath: root + "/docs", withIntermediateDirectories: true
            )
            try "read me".write(toFile: root + "/readme.txt", atomically: false, encoding: .utf8)
            try "api".write(toFile: root + "/docs/api.md", atomically: false, encoding: .utf8)
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }

        func member(_ innerPath: String) -> VFSPath {
            VFSPath(backend: .archive(forArchiveAt: archive), path: innerPath)
        }

        func contents(of innerPath: String) throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root + innerPath).sorted()
        }

        func text(of innerPath: String) throws -> String {
            try String(contentsOfFile: root + innerPath, encoding: .utf8)
        }
    }
}
