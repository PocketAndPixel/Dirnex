import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The Settings row for `git mergetool` (PLAN.md §M37 Slice 6), over a config held in memory.
@Suite("git merge tool: the Settings row")
@MainActor
struct GitMergeToolModelTests {
    /// `git config --global` over a dictionary, as far as the setup uses it.
    private final class Config: GitTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]
        var failure: GitRunFailure?

        init(_ values: [String: String] = [:]) {
            self.values = values
        }

        func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
            if let failure { throw failure }
            let parts = Array(arguments.dropFirst(2)).filter { $0 != "--type=bool" }
            let answer: Data? = lock.withLock {
                switch parts.first {
                case "--get":
                    return values[parts[1]].map { Data(($0 + "\n").utf8) }
                case "--unset":
                    values[parts[1]] = nil
                case "--remove-section":
                    values = values.filter { !$0.key.hasPrefix(parts[1] + ".") }
                default:
                    values[parts[0]] = parts[1]
                }
                return Data()
            }
            guard let answer else { throw GitRunFailure(status: 1, message: "") }
            return answer
        }
    }

    private let binary = "/Applications/Dirnex.app/Contents/MacOS/Dirnex"

    private func model(_ config: Config) -> GitMergeToolModel {
        GitMergeToolModel(transport: config, executablePath: binary)
    }

    private func set(by binary: String) -> [String: String] {
        [
            "merge.tool": "dirnex",
            "mergetool.dirnex.cmd": GitMergeToolSetup.command(executablePath: binary),
            "mergetool.dirnex.trustExitCode": "true"
        ]
    }

    @Test("before it has read anything the row says nothing")
    func reading() {
        let row = model(Config())
        #expect(row.shown == .reading)
        #expect(row.footer.isEmpty)
    }

    @Test("a Mac with no git says so")
    func noGit() async {
        let row = GitMergeToolModel(transport: nil, executablePath: binary)
        await row.refresh()
        #expect(row.shown == .noGit)
        #expect(row.footer == "git wasn’t found on this Mac.")
    }

    @Test("Use Dirnex sets it up, and Stop Using takes it away")
    func useAndStop() async {
        let row = model(Config())
        await row.refresh()
        #expect(row.shown == .state(.notSetUp(otherTool: nil)))
        await row.use()
        #expect(row.shown == .state(.active))
        #expect(!row.isChanging)
        await row.stopUsing()
        #expect(row.shown == .state(.notSetUp(otherTool: nil)))
    }

    @Test("the tool it would replace is named")
    func replaces() async {
        let row = model(Config(["merge.tool": "vimdiff"]))
        await row.refresh()
        #expect(row.shown == .state(.notSetUp(otherTool: "vimdiff")))
        #expect(row.footer.contains("vimdiff"))
    }

    @Test("another copy's setup is shown, and Use This Copy replaces it")
    func otherCopy() async {
        let row = model(Config(set(by: "/Users/me/old/Dirnex")))
        await row.refresh()
        #expect(row.footer.contains("/Users/me/old/Dirnex"))
        await row.use()
        #expect(row.shown == .state(.active))
    }

    @Test("a config git can't read shows git's words and offers nothing")
    func readFails() async {
        let config = Config()
        config.failure = GitRunFailure(status: 128, message: "fatal: bad config line 3")
        let row = model(config)
        await row.refresh()
        #expect(row.shown == .readFailed("fatal: bad config line 3"))
        #expect(row.footer.contains("fatal: bad config line 3"))
    }

    @Test("a write that fails says so, and a later success clears it")
    func writeFails() async {
        let config = Config()
        let row = model(config)
        await row.refresh()
        config.failure = GitRunFailure(status: 4, message: "could not lock config file")
        await row.use()
        #expect(row.changeFailure == "could not lock config file")
        #expect(row.footer.contains("could not lock config file"))
        #expect(!row.isChanging)
        config.failure = nil
        await row.use()
        #expect(row.changeFailure == nil)
        #expect(row.shown == .state(.active))
    }

    @Test("this copy's model runs the binary it is")
    func thisCopy() async throws {
        let row = GitMergeToolModel.forThisCopy()
        #expect(row.shown == .reading)
        let path = try #require(Bundle.main.executablePath)
        #expect(path.hasSuffix("/Contents/MacOS/Dirnex"))
    }
}
