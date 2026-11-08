import Foundation
import Testing

@testable import DirnexCore

/// Answers `git config` from a table of what each key holds, and records every run in order.
final class ScriptedGitConfig: GitTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [[String]] = []
    private var values: [String: String]
    /// Runs matching this answer as a git failure with this status.
    private let failing: (@Sendable ([String]) -> GitRunFailure?)?

    init(values: [String: String] = [:], failing: (@Sendable ([String]) -> GitRunFailure?)? = nil) {
        self.values = values
        self.failing = failing
    }

    var recorded: [[String]] {
        lock.withLock { runs }
    }

    /// The runs that write, without the leading `config --global`.
    var writes: [[String]] {
        recorded.map { Array($0.dropFirst(2)) }.filter { !$0.contains("--get") }
    }

    func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
        let result: Result<Data, GitRunFailure> = lock.withLock {
            runs.append(arguments)
            if let failure = failing?(arguments) { return .failure(failure) }
            if arguments.contains("--get"), let key = arguments.last {
                guard let value = values[key] else {
                    return .failure(GitRunFailure(status: 1, message: ""))
                }
                return .success(Data((value + "\n").utf8))
            }
            return .success(Data())
        }
        return try result.get()
    }
}

/// Making Dirnex git's merge tool (PLAN.md §M37 Slice 6).
@Suite("git merge tool: setting it up")
struct GitMergeToolSetupTests {
    private let binary = "/Applications/Dirnex.app/Contents/MacOS/Dirnex"

    private var ours: String {
        GitMergeToolSetup.command(executablePath: binary)
    }

    @Test("the command names the binary and leaves the four variables to git's shell")
    func command() {
        #expect(ours == "'\(binary)' --git-merge \"$LOCAL\" \"$BASE\" \"$REMOTE\" \"$MERGED\"")
    }

    @Test("a quote in the binary's path is closed, escaped and reopened")
    func commandQuote() {
        #expect(
            GitMergeToolSetup.command(executablePath: "/a b/it's").hasPrefix(
                "'/a b/it'\\''s' --git-merge"
            )
        )
    }

    // MARK: - What the config amounts to

    @Test("nothing set is not set up, with no other tool")
    func stateEmpty() {
        #expect(
            GitMergeToolSetup.state(
                mergeTool: nil,
                command: nil,
                trustExitCode: false,
                executablePath: binary
            ) ==
                .notSetUp(otherTool: nil)
        )
    }

    @Test("another tool is named, whatever else is set")
    func stateOtherTool() {
        #expect(GitMergeToolSetup.state(
            mergeTool: "vimdiff",
            command: nil,
            trustExitCode: false,
            executablePath: binary
        ) == .notSetUp(otherTool: "vimdiff"))
        #expect(GitMergeToolSetup.state(
            mergeTool: "vimdiff",
            command: ours,
            trustExitCode: true,
            executablePath: binary
        ) == .notSetUp(otherTool: "vimdiff"))
    }

    @Test("this copy's command under merge.tool, trusted, is active")
    func stateActive() {
        #expect(GitMergeToolSetup.state(
            mergeTool: "dirnex",
            command: ours,
            trustExitCode: true,
            executablePath: binary
        ) == .active)
    }

    @Test("another copy's command is named")
    func stateOtherCopy() {
        let other = GitMergeToolSetup.command(
            executablePath: "/Users/me/old/Dirnex.app/Contents/MacOS/Dirnex"
        )
        #expect(GitMergeToolSetup.state(
            mergeTool: "dirnex",
            command: other,
            trustExitCode: true,
            executablePath: binary
        ) == .otherCopy(command: other))
    }

    @Test("this copy's command without trustExitCode is not set up, since git would ask")
    func stateUntrusted() {
        #expect(GitMergeToolSetup.state(
            mergeTool: "dirnex",
            command: ours,
            trustExitCode: false,
            executablePath: binary
        ) == .notSetUp(otherTool: nil))
    }

    @Test("merge.tool naming Dirnex with no command is not set up, and names no other tool")
    func stateNoCommand() {
        #expect(GitMergeToolSetup.state(
            mergeTool: "dirnex",
            command: nil,
            trustExitCode: true,
            executablePath: binary
        ) == .notSetUp(otherTool: nil))
    }

    // MARK: - Reading

    @Test("reading asks for the trust as a boolean, and only of the global config")
    func readArguments() throws {
        let git = ScriptedGitConfig()
        #expect(
            try GitMergeToolSetup.read(executablePath: binary, transport: git) == .notSetUp(
                otherTool: nil
            )
        )
        #expect(git.recorded.allSatisfy { Array($0.prefix(2)) == ["config", "--global"] })
        #expect(
            git.recorded.contains(
                ["config", "--global", "--type=bool", "--get", "mergetool.dirnex.trustExitCode"]
            )
        )
    }

    @Test("what git holds becomes the state")
    func readActive() throws {
        let git = ScriptedGitConfig(values: [
            "merge.tool": "dirnex",
            "mergetool.dirnex.cmd": ours,
            "mergetool.dirnex.trustExitCode": "true"
        ])
        #expect(try GitMergeToolSetup.read(executablePath: binary, transport: git) == .active)
    }

    @Test("a trust value that is not a boolean counts as untrusted")
    func readBadBool() throws {
        let git = ScriptedGitConfig(
            values: ["merge.tool": "dirnex", "mergetool.dirnex.cmd": ours],
            failing: { arguments in
                arguments.contains("--type=bool") ? GitRunFailure(
                    status: 128,
                    message: "fatal: bad boolean"
                ) : nil
            }
        )
        #expect(
            try GitMergeToolSetup.read(executablePath: binary, transport: git) == .notSetUp(
                otherTool: nil
            )
        )
    }

    @Test("a config git can't read is a failure, not an empty config")
    func readFailure() {
        let git = ScriptedGitConfig(
            failing: { _ in GitRunFailure(status: 128, message: "fatal: bad config") }
        )
        #expect(throws: GitRunFailure(status: 128, message: "fatal: bad config")) {
            try GitMergeToolSetup.read(executablePath: binary, transport: git)
        }
    }

    @Test("a git that can't be started is a failure")
    func readNoGit() {
        let git = ScriptedGitConfig(failing: { _ in GitRunFailure(status: nil, message: "") })
        #expect(throws: GitRunFailure(status: nil, message: "")) {
            try GitMergeToolSetup.read(executablePath: binary, transport: git)
        }
    }

    // MARK: - Writing

    @Test("setting up writes the command, the trust and then merge.tool")
    func applies() throws {
        let git = ScriptedGitConfig()
        try GitMergeToolSetup.apply(executablePath: binary, transport: git)
        #expect(git.writes == [
            ["mergetool.dirnex.cmd", ours],
            ["mergetool.dirnex.trustExitCode", "true"],
            ["merge.tool", "dirnex"]
        ])
    }

    @Test("a write that fails leaves merge.tool alone")
    func applyFails() {
        let git = ScriptedGitConfig(failing: { arguments in
            arguments.contains("mergetool.dirnex.trustExitCode") ? GitRunFailure(
                status: 4,
                message: "locked"
            ) : nil
        })
        #expect(throws: GitRunFailure(status: 4, message: "locked")) {
            try GitMergeToolSetup.apply(executablePath: binary, transport: git)
        }
        #expect(!git.writes.contains { $0.first == "merge.tool" })
    }

    @Test("removing takes merge.tool first while it names Dirnex, then the section")
    func removes() throws {
        let git = ScriptedGitConfig(values: ["merge.tool": "dirnex"])
        try GitMergeToolSetup.remove(transport: git)
        #expect(git.writes == [["--unset", "merge.tool"], ["--remove-section", "mergetool.dirnex"]])
    }

    @Test("removing leaves another tool's merge.tool")
    func removeKeepsOtherTool() throws {
        let git = ScriptedGitConfig(values: ["merge.tool": "vimdiff"])
        try GitMergeToolSetup.remove(transport: git)
        #expect(git.writes == [["--remove-section", "mergetool.dirnex"]])
    }

    @Test("removing what is already gone is no failure")
    func removeTwice() throws {
        let git = ScriptedGitConfig(failing: { arguments in
            arguments.contains("--remove-section") ? GitRunFailure(
                status: 128,
                message: "fatal: no such section"
            ) : nil
        })
        try GitMergeToolSetup.remove(transport: git)
    }

    @Test("a config that can't be written is a failure")
    func removeFails() {
        let git = ScriptedGitConfig(failing: { arguments in
            arguments.contains("--remove-section") ? GitRunFailure(status: 4, message: "locked") : nil
        })
        #expect(throws: GitRunFailure(status: 4, message: "locked")) {
            try GitMergeToolSetup.remove(transport: git)
        }
    }
}
