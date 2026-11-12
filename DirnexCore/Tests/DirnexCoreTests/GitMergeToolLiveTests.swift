import Foundation
import Testing

@testable import DirnexCore

/// The setup against a real `git`, with a scratch global config, and the command it writes run by a
/// real `git mergetool` (PLAN.md §M37 Slice 6). The tool is a shell script standing in for Dirnex at
/// a path no shell would take unquoted.
@Suite("git merge tool: with real git")
struct GitMergeToolLiveTests {
    /// `git`, its global config kept in a file of the test's own.
    private struct Config: GitTransport {
        let file: String

        func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
            let result: GitRun
            do {
                result = try GitScratchRepository.launch(arguments, globalConfig: file)
            } catch {
                throw GitRunFailure(status: nil, message: "\(error)")
            }
            guard result.status == 0 else {
                throw GitRunFailure(
                    status: result.status,
                    // swiftlint:disable:next optional_data_string_conversion
                    message: String(decoding: result.errors, as: UTF8.self)
                )
            }
            return result.output
        }
    }

    /// A repository with one file in the state a test asks for, a stand-in tool and a global
    /// config. The tool records its arguments and exits with what `status` holds.
    private struct Rig {
        let repository: GitScratchRepository
        let folder: TempTree
        let config: Config
        let tool: String
        let log: String
        let status: String

        init() throws {
            repository = try GitScratchRepository()
            folder = try TempTree()
            let directory = try folder.makeDir("odd dir/it's $here")
            tool = directory + "/Dirnex"
            log = folder.path("log")
            status = folder.path("status")
            config = Config(file: folder.path("gitconfig"))
            try Data().write(to: URL(fileURLWithPath: config.file))
            let script = """
            #!/bin/bash
            for argument in "$@"; do printf '%s\\n' "$argument" >> '\(log)'; done
            printf 'pwd=%s\\n' "$(pwd -P)" >> '\(log)'
            exit "$(cat '\(status)')"
            """
            try Data(script.utf8).write(to: URL(fileURLWithPath: tool))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
            try setStatus(0)
        }

        func setStatus(_ code: Int) throws {
            try Data("\(code)".utf8).write(to: URL(fileURLWithPath: status))
        }

        func cleanup() {
            repository.cleanup()
            folder.cleanup()
        }

        /// The tool's recorded arguments, one per line.
        func recorded() throws -> [String] {
            try String(contentsOfFile: log, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }

        /// Leave `file` conflicted between two branches: `both modified` or, with `added`, both
        /// sides adding it.
        func conflict(_ file: String, added: Bool = false) throws {
            if !added { try repository.write(file, "one\n") }
            try repository.write("keep.txt", "keep\n")
            try repository.commit("base")
            try repository.git("checkout", "-q", "-b", "other")
            try repository.write(file, "theirs\n")
            try repository.commit("theirs")
            try repository.git("checkout", "-q", "main")
            try repository.write(file, "yours\n")
            try repository.commit("yours")
            _ = try repository.run(["merge", "other"])
        }

        /// `git mergetool` run with this rig's config, from `folder` of the repository.
        func mergetool(in folder: String = ".") throws -> GitRun {
            try GitScratchRepository.launch(
                ["-C", repository.tree.path(folder), "mergetool", "--no-prompt"],
                globalConfig: config.file
            )
        }

        func statusLines() throws -> String {
            try repository.git("status", "--short", "--untracked-files=no")
        }
    }

    @Test("setting up and reading back through a real git")
    func roundTrip() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        let setup = GitMergeToolSetup.self
        #expect(
            try setup.read(executablePath: rig.tool, transport: rig.config) == .notSetUp(
                otherTool: nil
            )
        )
        try setup.apply(executablePath: rig.tool, transport: rig.config)
        #expect(try setup.read(executablePath: rig.tool, transport: rig.config) == .active)
        #expect(try setup.read(executablePath: "/elsewhere/Dirnex", transport: rig.config) ==
            .otherCopy(command: setup.command(executablePath: rig.tool)))
        try setup.remove(transport: rig.config)
        #expect(
            try setup.read(executablePath: rig.tool, transport: rig.config) == .notSetUp(
                otherTool: nil
            )
        )
        try setup.remove(transport: rig.config)
    }

    @Test("what the user had in the config stays, and another tool is reported")
    func keepsTheRest() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        _ = try rig.config.run(["config", "--global", "user.name", "Me"])
        _ = try rig.config.run(["config", "--global", "merge.tool", "vimdiff"])
        let setup = GitMergeToolSetup.self
        #expect(
            try setup.read(executablePath: rig.tool, transport: rig.config) == .notSetUp(
                otherTool: "vimdiff"
            )
        )
        try setup.apply(executablePath: rig.tool, transport: rig.config)
        try setup.remove(transport: rig.config)
        let output = try rig.config.run(["config", "--global", "--list"])
        // swiftlint:disable:next optional_data_string_conversion
        #expect(String(decoding: output, as: UTF8.self) == "user.name=Me\n")
    }

    @Test("a real git mergetool runs the command it wrote, past a hostile path, with four paths")
    func runsTheCommand() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try GitMergeToolSetup.apply(executablePath: rig.tool, transport: rig.config)
        try rig.repository.write("sub/placeholder", "x\n")
        try rig.conflict("sub/a b.txt")
        let run = try rig.mergetool(in: "sub")
        #expect(run.status == 0)
        let recorded = try rig.recorded()
        try #require(recorded.count == 6)
        #expect(recorded[0] == GitMergeArguments.flag)
        #expect(recorded[1].hasSuffix(".txt") && recorded[1].contains("_LOCAL_"))
        #expect(recorded[2].contains("_BASE_"))
        #expect(recorded[3].contains("_REMOTE_"))
        #expect(recorded[4] == "sub/a b.txt")
        #expect(
            try URL(fileURLWithPath: String(recorded[5].dropFirst(4))).resolvingSymlinksInPath().path ==
                URL(fileURLWithPath: rig.repository.root).resolvingSymlinksInPath().path
        )
        // And what the command would make of them is what git meant, from the folder git ran it in.
        let request = try #require(GitMergeArguments.request(
            from: ["Dirnex"] + Array(recorded[0...4]),
            currentDirectory: String(recorded[5].dropFirst(4))
        ))
        #expect(request.merged.hasSuffix("/sub/a b.txt"))
        #expect(request.name == "a b.txt")
    }

    @Test("exit 0 stages a both-modified file")
    func zeroStages() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try GitMergeToolSetup.apply(executablePath: rig.tool, transport: rig.config)
        try rig.conflict("a.txt")
        #expect(try rig.statusLines().contains("UU a.txt"))
        #expect(try rig.mergetool().status == 0)
        #expect(try rig.statusLines().contains("M  a.txt"))
    }

    @Test("exit 1 leaves a both-modified file conflicted, without git asking whether it worked")
    func oneFails() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try GitMergeToolSetup.apply(executablePath: rig.tool, transport: rig.config)
        try rig.setStatus(1)
        try rig.conflict("a.txt")
        let run = try rig.mergetool()
        #expect(run.status != 0)
        // swiftlint:disable:next optional_data_string_conversion
        let printed = String(decoding: run.output + run.errors, as: UTF8.self)
        #expect(printed.contains("merge of a.txt failed"))
        #expect(try rig.statusLines().contains("UU a.txt"))
    }

    @Test("a file both sides added reaches the tool with an empty base, and exit 0 stages it")
    func addAdd() throws {
        let rig = try Rig()
        defer { rig.cleanup() }
        try GitMergeToolSetup.apply(executablePath: rig.tool, transport: rig.config)
        try rig.conflict("added.txt", added: true)
        #expect(try rig.statusLines().contains("AA added.txt"))
        #expect(try rig.mergetool().status == 0)
        // Staged against HEAD, which already holds yours' version of it.
        #expect(try rig.statusLines().contains("M  added.txt"))
        #expect(try rig.recorded()[2].contains("_BASE_"))
    }
}
