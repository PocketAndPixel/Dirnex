import DirnexCore
import Foundation

@testable import Dirnex

/// A scratch repository stopped on a merge conflict, built with the git the app runs. Setting up
/// keeps the user's configuration out; the reads under test run as the app runs them, so the
/// repository's own `core.autocrlf` is pinned off against a global one.
///
/// Built and read off the main actor (`make`, `ResolveConflictTests.read`): the app suite's tests
/// share the main run loop, and a git run waited for there holds back every other test's timers.
struct ConflictRepository {
    /// A git run that did not go as the fixture needs.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let root: URL

    var path: String {
        root.path
    }

    /// `base` committed, `theirs` on a branch, `ours` on `main`, and `git merge theirs` stopped on
    /// the conflicts. A `nil` content deletes the file.
    init(
        base: [String: Data],
        ours: [String: Data?],
        theirs: [String: Data?]
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-conflict-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "test@example.com")
        try git("config", "user.name", "Test")
        try git("config", "core.autocrlf", "false")
        try apply(base)
        try commit("base")
        try git("checkout", "-q", "-b", "theirs")
        try apply(theirs)
        try commit("theirs")
        try git("checkout", "-q", "main")
        try apply(ours)
        try commit("ours")
        guard try run(["merge", "theirs"]) == 1 else {
            throw Failure(description: "the merge was meant to stop on a conflict")
        }
    }

    /// `init(base:ours:theirs:)`, run on a thread of its own.
    static func make(
        base: [String: Data],
        ours: [String: Data?],
        theirs: [String: Data?]
    ) async throws -> ConflictRepository {
        try await BlockingWork.run {
            Result { try ConflictRepository(base: base, ours: ours, theirs: theirs) }
        }.get()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ name: String) -> String {
        root.appendingPathComponent(name).path
    }

    func contents(_ name: String) -> String {
        (try? String(contentsOfFile: file(name), encoding: .utf8)) ?? "<none>"
    }

    private func apply(_ changes: [String: Data?]) throws {
        for (name, contents) in changes {
            if let contents {
                try contents.write(to: root.appendingPathComponent(name))
            } else {
                try git("rm", "-q", name)
            }
        }
    }

    private func commit(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    func git(_ arguments: String...) throws {
        guard try run(arguments) == 0 else {
            throw Failure(description: "git \(arguments.joined(separator: " ")) failed")
        }
    }

    /// git's exit status, with its output going to a file rather than a pipe. Waited for without
    /// `waitUntilExit`, which runs the calling thread's run loop and so other tests' work with it.
    @discardableResult
    func run(_ arguments: [String], output: URL? = nil) throws -> Int32 {
        guard let executable = GitProcessTransport.executablePath else {
            throw Failure(description: "no git to run")
        }
        let sink = output ?? URL(fileURLWithPath: "/dev/null")
        if output != nil { try Data().write(to: sink) }
        let handle = try FileHandle(forWritingTo: sink)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-C", path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        exited.wait()
        return process.terminationStatus
    }

    /// What `git status --porcelain` says, read without taking the index's lock.
    func status() throws -> String {
        let output = root.deletingLastPathComponent()
            .appendingPathComponent("dirnex-status-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard try run(["--no-optional-locks", "status", "--porcelain"], output: output) == 0 else {
            throw Failure(description: "git status failed")
        }
        return try String(contentsOf: output, encoding: .utf8)
    }

    /// Every item under `.git`, with its size and modification time.
    func gitDirectoryState() throws -> [String: String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let walk = FileManager.default.enumerator(
            at: root.appendingPathComponent(".git"),
            includingPropertiesForKeys: keys
        )
        var state: [String: String] = [:]
        while let url = walk?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            state[url.path] = "\(values.fileSize ?? -1) \(stamp)"
        }
        return state
    }

    /// The target Resolve Conflict… would act on for `name`.
    func target(_ name: String) throws -> ConflictTarget {
        let path = VFSPath.local(file(name))
        let entry = try LocalBackend().stat(at: path)
        return ConflictTarget(entry: entry, repositoryRoot: .local(self.path), relativePath: name)
    }
}
