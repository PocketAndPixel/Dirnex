import Foundation
import Testing

@testable import DirnexCore

/// A throwaway git repository for the live conflict tests (PLAN.md §M34 Slice 5), with git's
/// configuration kept out as `GitMergeOracle` keeps it out, so a user's `merge.conflictStyle` or
/// `core.autocrlf` cannot change what a test sees.
struct GitScratchRepository {
    let tree: TempTree

    var root: String {
        tree.root.path
    }

    init() throws {
        tree = try TempTree()
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
    }

    func cleanup() {
        tree.cleanup()
    }

    func write(_ name: String, _ contents: String) throws {
        let url = URL(fileURLWithPath: tree.path(name))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    /// Commit everything as it stands.
    func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// Run git in the repository, which must exit 0. Its output.
    @discardableResult
    func git(_ arguments: String...) throws -> String {
        let (status, output) = try run(arguments)
        try #require(status == 0, "git \(arguments.joined(separator: " ")) exited \(status)")
        return output
    }

    /// Run git in the repository whatever it exits with, as a merge that conflicts exits 1.
    @discardableResult
    func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let result = try Self.launch(["-C", root] + arguments)
        // swiftlint:disable:next optional_data_string_conversion
        return (result.status, String(decoding: result.output, as: UTF8.self))
    }

    /// The transport the reader is handed, running the same git the same way.
    var transport: ProcessGitTransport {
        ProcessGitTransport()
    }

    /// Run `/usr/bin/git`, with its standard output and error going to files rather than pipes:
    /// many processes launched with pipes from several threads failed with `EBADF`
    /// (docs/NOTES.md ▸ Fixtures and shared state).
    static func launch(_ arguments: [String]) throws -> GitRun {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outputURL = scratch.appendingPathComponent("out")
        let errorsURL = scratch.appendingPathComponent("err")
        try Data().write(to: outputURL)
        try Data().write(to: errorsURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorsURL)
        defer {
            try? output.close()
            try? errors.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        return try GitRun(
            status: process.terminationStatus,
            output: Data(contentsOf: outputURL),
            errors: Data(contentsOf: errorsURL)
        )
    }

    /// Every item under the git directory, with its size and modification time: what a write by
    /// any git command would change.
    func gitDirectoryState() throws -> [String: String] {
        let gitDirectory = URL(fileURLWithPath: tree.path(".git"))
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(
            at: gitDirectory,
            includingPropertiesForKeys: keys
        )
        else { return [:] }
        var state: [String: String] = [:]
        for case let url as URL in walk {
            let values = try url.resourceValues(forKeys: Set(keys))
            let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            state[url.path] = "\(values.fileSize ?? -1) \(stamp)"
        }
        return state
    }
}

/// One git run's exit status and what it printed.
struct GitRun {
    let status: Int32
    let output: Data
    let errors: Data
}

/// `GitTransport` over `/usr/bin/git`, for the live tests. The app's own transport is the app's.
struct ProcessGitTransport: GitTransport {
    func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
        let result: GitRun
        do {
            result = try GitScratchRepository.launch(arguments)
        } catch {
            throw GitRunFailure(status: nil, message: "\(error)")
        }
        guard result.status == 0 else {
            throw GitRunFailure(
                status: result.status,
                // swiftlint:disable:next optional_data_string_conversion
                message: String(decoding: result.errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.output
    }
}
