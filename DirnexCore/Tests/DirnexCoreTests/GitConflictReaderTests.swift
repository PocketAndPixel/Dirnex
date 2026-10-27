import Foundation
import Testing

@testable import DirnexCore

/// `GitConflictReader` against a scripted git, which answers each subcommand and records what it
/// was asked.
@Suite("GitConflictReader")
struct GitConflictReaderTests {
    /// Answers by subcommand: `ls-files` with `listing`, `rev-parse` with `gitDirectory`, and
    /// `cat-file` with `contents[object]`. A `nil` answer fails as git would.
    final class ScriptedGit: GitTransport, @unchecked Sendable {
        let listing: Data?
        let gitDirectory: String?
        let contents: [String: Data]
        private let lock = NSLock()
        private var calls: [[String]] = []

        init(
            listing: String?,
            gitDirectory: String? = "/repo/.git",
            contents: [String: String] = [:]
        ) {
            self.listing = listing.map { Data($0.utf8) }
            self.gitDirectory = gitDirectory
            self.contents = contents.mapValues { Data($0.utf8) }
        }

        var asked: [[String]] {
            lock.withLock { calls }
        }

        /// The subcommand of each run, in order.
        var subcommands: [String] {
            asked.map { arguments in
                arguments.first { ["ls-files", "rev-parse", "cat-file"].contains($0) } ?? "?"
            }
        }

        func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
            lock.withLock { calls.append(arguments) }
            let failure = GitRunFailure(status: 128, message: "fatal: scripted")
            if arguments.contains("ls-files") {
                guard let listing else { throw failure }
                return listing
            }
            if arguments.contains("rev-parse") {
                guard let gitDirectory else { throw failure }
                return Data((gitDirectory + "\n").utf8)
            }
            guard let object = arguments.last, let data = contents[object] else { throw failure }
            return data
        }
    }

    private func read(
        _ path: String = "f.txt",
        from git: ScriptedGit,
        byteLimit: Int64 = 1000,
        existing: Set<String> = ["/repo/.git/MERGE_HEAD"]
    ) throws(GitConflictReader.Failure) -> GitConflictVersions {
        try GitConflictReader.read(
            path,
            inRepositoryAt: "/repo",
            byteLimit: byteLimit,
            transport: git,
            exists: { existing.contains($0) }
        )
    }

    private func failure(
        _ path: String = "f.txt",
        from git: ScriptedGit,
        byteLimit: Int64 = 1000
    ) -> GitConflictReader.Failure? {
        do {
            _ = try read(path, from: git, byteLimit: byteLimit)
            return nil
        } catch {
            return error
        }
    }

    private static let bothModified = """
    100644 b1 1 5\tf.txt\0100644 o2 2 5\tf.txt\0100644 t3 3 5\tf.txt\0
    """

    @Test("both modified: the list, the git directory, then each version")
    func readsThreeVersions() throws {
        let git = ScriptedGit(
            listing: Self.bothModified,
            contents: ["b1": "base\n", "o2": "ours\n", "t3": "theirs\n"]
        )
        let versions = try read(from: git)
        #expect(versions == GitConflictVersions(
            operation: .merge,
            base: Data("base\n".utf8),
            ours: Data("ours\n".utf8),
            theirs: Data("theirs\n".utf8)
        ))
        #expect(git.subcommands == ["ls-files", "rev-parse", "cat-file", "cat-file", "cat-file"])
        #expect(git.asked.dropFirst(2).map { $0.last } == ["b1", "o2", "t3"])
    }

    @Test("both added: no base is read")
    func bothAdded() throws {
        let git = ScriptedGit(
            listing: "100644 o2 2 5\tf.txt\0100644 t3 3 5\tf.txt\0",
            contents: ["o2": "ours\n", "t3": "theirs\n"]
        )
        let versions = try read(from: git)
        #expect(versions.base == nil)
        #expect(versions.ours == Data("ours\n".utf8))
        #expect(git.subcommands == ["ls-files", "rev-parse", "cat-file", "cat-file"])
    }

    @Test("a refusal reads nothing past the list")
    func refusalReadsNothing() {
        let git = ScriptedGit(listing: "100644 b1 1 5\tf.txt\0100644 t3 3 5\tf.txt\0")
        #expect(failure(from: git) == .refused(.deletedByUs))
        #expect(git.subcommands == ["ls-files"])
    }

    @Test("a path git no longer lists is not conflicted")
    func resolvedSince() {
        let git = ScriptedGit(listing: "")
        #expect(failure(from: git) == .refused(.notConflicted))
    }

    @Test("a version over the limit refuses the read before any bytes")
    func tooLarge() {
        let git = ScriptedGit(listing: """
        100644 b1 1 5\tf.txt\0100644 o2 2 5\tf.txt\0100644 t3 3 2000\tf.txt\0
        """)
        #expect(failure(from: git) == .tooLarge(byteSize: 2000))
        #expect(git.subcommands == ["ls-files"])
        // At the limit is within it.
        let atLimit = ScriptedGit(
            listing: Self.bothModified,
            contents: ["b1": "", "o2": "", "t3": ""]
        )
        #expect(failure(from: atLimit, byteLimit: 5) == nil)
    }

    @Test("only the path asked about counts, spelled either way")
    func onlyItsOwnRecords() throws {
        // A literal path that names a folder lists what is under it; none of it is this file.
        let folder = ScriptedGit(listing: "100644 o2 2 5\tdir/a.txt\0100644 t3 3 5\tdir/a.txt\0")
        #expect(failure("dir", from: folder) == .refused(.notConflicted))
        // git prints the name precomposed; the pane's path may spell it decomposed. `--path` takes
        // git's own spelling.
        let precomposed = "caf\u{E9}.txt"
        let decomposed = "cafe\u{301}.txt"
        let git = ScriptedGit(
            listing: "100644 o2 2 5\t\(precomposed)\0100644 t3 3 5\t\(precomposed)\0",
            contents: ["o2": "ours\n", "t3": "theirs\n"]
        )
        _ = try read(decomposed, from: git)
        // Scalars, since `String`s that are canonically equivalent are equal.
        func scalars(_ text: String?) -> [Unicode.Scalar] {
            Array((text ?? "").unicodeScalars)
        }
        #expect(scalars(git.asked[0].last) == scalars(decomposed))
        for arguments in git.asked.dropFirst(2) {
            #expect(
                scalars(arguments.first { $0.hasPrefix("--path=") }) == scalars(
                    "--path=\(precomposed)"
                )
            )
        }
    }

    @Test("git failing to list or to read is reported with its words")
    func gitFailures() {
        let failed = GitRunFailure(status: 128, message: "fatal: scripted")
        #expect(failure(from: ScriptedGit(listing: nil)) == .gitFailed(failed))
        let missingObject = ScriptedGit(listing: Self.bothModified, contents: ["b1": "", "o2": ""])
        #expect(failure(from: missingObject) == .gitFailed(failed))
    }

    @Test("with no git directory the versions still read, with nothing in progress named")
    func noGitDirectory() throws {
        let git = ScriptedGit(
            listing: Self.bothModified,
            gitDirectory: nil,
            contents: ["b1": "", "o2": "", "t3": ""]
        )
        #expect(try read(from: git).operation == .other)
        let relative = ScriptedGit(
            listing: Self.bothModified,
            gitDirectory: ".git",
            contents: ["b1": "", "o2": "", "t3": ""]
        )
        #expect(try read(from: relative, existing: [".git/MERGE_HEAD"]).operation == .other)
    }
}
