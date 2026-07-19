import Foundation
import Testing

@testable import DirnexCore

/// The `onError` hook — the engine yielding control per failed source to a resolver, the core
/// half of TC's per-file "Skip / Retry / Abort" error dialog (PLAN.md §M2). The resolver
/// stands in for the app's dialog: the tests script its answers and assert that the engine
/// consults it exactly on the failing items, honours each `ErrorResolution` (skip collects and
/// carries on, retry re-attempts, abort unwinds the whole op), and — with no resolver — keeps
/// its unattended default of collecting the failure and moving on.
@Suite("CopyEngine error handling")
struct CopyEngineErrorTests {
    private let fs = LocalBackend()

    private func stat(_ tree: TempTree, _ relative: String) throws -> FileEntry {
        try fs.stat(at: tree.vfsPath(relative))
    }

    private func contents(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    private func exists(_ tree: TempTree, _ relative: String) -> Bool {
        (try? fs.stat(at: tree.vfsPath(relative))) != nil
    }

    /// A two-file source tree over an empty `dest`, so tests copy `bad.txt` (which a fault
    /// backend fails) alongside `good.txt` (which always copies).
    private func twoFileTree() throws -> TempTree {
        let tree = try TempTree()
        try tree.writeFile("bad.txt", contents: "BAD")
        try tree.writeFile("good.txt", contents: "GOOD")
        try tree.makeDir("dest")
        return tree
    }

    private func copyOp(_ tree: TempTree, sources: [String]) throws -> FileOperation {
        FileOperation(
            kind: .copy,
            sources: try sources.map { try stat(tree, $0) },
            destinationDirectory: tree.vfsPath("dest")
        )
    }

    // MARK: - Skip

    @Test("onError → skip collects the failure and the other sources still copy")
    func errorSkipCollectsAndContinues() throws {
        let tree = try twoFileTree()
        defer { tree.cleanup() }
        let backend = MutableFaultBackend(failing: "bad.txt", with: { .permissionDenied($0) })
        let resolver = ScriptedErrorResolver { _ in .skip }

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["bad.txt", "good.txt"]),
            using: backend,
            onError: { resolver.resolve($0) }
        )

        #expect(!report.succeeded)
        #expect(!report.wasCancelled)
        #expect(report.completedItems == 1)
        #expect(report.failures.map(\.path) == [tree.vfsPath("bad.txt")])
        #expect(report.failures.first?.error == .permissionDenied(tree.vfsPath("bad.txt")))
        #expect(resolver.callCount == 1) // only the failing source asked
        #expect(resolver.contexts.first?.kind == .copy)
        #expect(try contents(tree, "dest/good.txt") == "GOOD")
        #expect(!exists(tree, "dest/bad.txt")) // no partial from the failed source
    }

    // MARK: - Retry

    @Test("onError → retry re-attempts and succeeds once the fault clears")
    func errorRetrySucceedsAfterTransientFault() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("flaky.txt", contents: "PAYLOAD")
        try tree.makeDir("dest")
        // Fail the first copy attempt, then let the retry through — a transient hiccup.
        let backend = MutableFaultBackend(
            failing: "flaky.txt",
            with: { .io(path: $0, code: EIO) },
            failuresBeforeSuccess: 1
        )
        let resolver = ScriptedErrorResolver { _ in .retry }

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["flaky.txt"]),
            using: backend,
            onError: { resolver.resolve($0) }
        )

        #expect(report.succeeded)
        #expect(report.failures.isEmpty)
        #expect(resolver.callCount == 1) // one failure → one retry → success
        #expect(try contents(tree, "dest/flaky.txt") == "PAYLOAD")
        // The failed-then-retried copy tallies the bytes once, not twice.
        #expect(report.completedBytes == Int64("PAYLOAD".utf8.count))
    }

    @Test("onError may retry several times before giving up with skip")
    func errorRetryThenGiveUp() throws {
        let tree = try twoFileTree()
        defer { tree.cleanup() }
        // Permanently unreadable: no `failuresBeforeSuccess`, so every attempt fails.
        let backend = MutableFaultBackend(failing: "bad.txt", with: { .permissionDenied($0) })
        // Retry twice, then relent and skip so the batch can finish.
        let resolver = ScriptedErrorResolver { context in
            context.attempt < 3 ? .retry : .skip
        }

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["bad.txt", "good.txt"]),
            using: backend,
            onError: { resolver.resolve($0) }
        )

        #expect(resolver.callCount == 3) // two retries + the final skip
        #expect(report.completedItems == 1)
        #expect(report.failures.map(\.path) == [tree.vfsPath("bad.txt")])
        #expect(try contents(tree, "dest/good.txt") == "GOOD")
    }

    // MARK: - Abort

    @Test("onError → abort unwinds the whole op, leaving later sources untouched")
    func errorAbortUnwinds() throws {
        let tree = try twoFileTree()
        defer { tree.cleanup() }
        let backend = MutableFaultBackend(failing: "bad.txt", with: { .permissionDenied($0) })
        let resolver = ScriptedErrorResolver { _ in .abort }

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["bad.txt", "good.txt"]),
            using: backend,
            onError: { resolver.resolve($0) }
        )

        #expect(report.wasCancelled)
        #expect(report.completedItems == 0)
        #expect(resolver.callCount == 1) // stopped at the first failure
        // Abort is the user's own decision — it doesn't also pile up a failure summary.
        #expect(report.failures.isEmpty)
        #expect(!exists(tree, "dest/good.txt")) // never reached the later source
    }

    @Test("a completed source before an abort is kept in the report")
    func errorAbortKeepsEarlierWork() throws {
        let tree = try twoFileTree()
        defer { tree.cleanup() }
        // `good.txt` first (copies), then `bad.txt` fails and the resolver aborts.
        let backend = MutableFaultBackend(failing: "bad.txt", with: { .permissionDenied($0) })
        let resolver = ScriptedErrorResolver { _ in .abort }

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["good.txt", "bad.txt"]),
            using: backend,
            onError: { resolver.resolve($0) }
        )

        #expect(report.wasCancelled)
        #expect(report.completedItems == 1) // good.txt already landed
        #expect(try contents(tree, "dest/good.txt") == "GOOD")
    }

    // MARK: - No resolver

    @Test("without an onError resolver a failure is collected and the op carries on")
    func noResolverDefaultsToSkip() throws {
        let tree = try twoFileTree()
        defer { tree.cleanup() }
        let backend = MutableFaultBackend(failing: "bad.txt", with: { .permissionDenied($0) })

        let report = CopyEngine.run(
            try copyOp(tree, sources: ["bad.txt", "good.txt"]),
            using: backend
        )

        #expect(!report.succeeded)
        #expect(!report.wasCancelled)
        #expect(report.completedItems == 1)
        #expect(report.failures.map(\.path) == [tree.vfsPath("bad.txt")])
        #expect(try contents(tree, "dest/good.txt") == "GOOD")
    }
}

// MARK: - Test doubles

/// A test stand-in for the app's error dialog: records every context the engine hands it —
/// including the running `attempt` count so a test can retry a fixed number of times — and
/// replies with a scripted `ErrorResolution`. The engine calls it synchronously on its copy
/// thread, so a plain recorder suffices (`@unchecked Sendable` to cross the closure boundary).
private final class ScriptedErrorResolver: @unchecked Sendable {
    /// One recorded call: the context plus its 1-based attempt number for this suite's asserts.
    struct Call {
        let kind: FileOperation.Kind
        let path: VFSPath
        let error: VFSError
        let attempt: Int
    }

    private let responder: @Sendable (Call) -> ErrorResolution
    private(set) var contexts: [Call] = []

    init(_ responder: @escaping @Sendable (Call) -> ErrorResolution) {
        self.responder = responder
    }

    func resolve(_ context: OperationErrorContext) -> ErrorResolution {
        let call = Call(
            kind: context.kind,
            path: context.path,
            error: context.error,
            attempt: contexts.count + 1
        )
        contexts.append(call)
        return responder(call)
    }

    var callCount: Int { contexts.count }
}

/// A `LocalBackend` wrapper that fails `copyFile` for a chosen source name — optionally only
/// for a fixed number of attempts, so a retry test can watch a transient fault clear. Cloning
/// is blocked so the copy actually reaches `copyFile`; everything else forwards to a real
/// `LocalBackend`. `@unchecked Sendable`: the engine runs single-threaded, so the attempt
/// counter is touched from one thread only.
private final class MutableFaultBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let failingName: String
    private let makeError: @Sendable (VFSPath) -> VFSError
    private var remainingFailures: Int

    /// - Parameters:
    ///   - failing: the last path component whose `copyFile` should fail.
    ///   - with: the error to raise for it.
    ///   - failuresBeforeSuccess: how many attempts fail before the copy is let through; the
    ///     default `.max` means it always fails (a permanent error).
    init(
        failing name: String,
        with makeError: @escaping @Sendable (VFSPath) -> VFSError,
        failuresBeforeSuccess: Int = .max
    ) {
        failingName = name
        self.makeError = makeError
        remainingFailures = failuresBeforeSuccess
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { try inner.listDirectory(at: path) }
    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }
    func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
    func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try inner.moveItem(at: source, to: destination)
    }

    // Force the chunked path so the copy reaches `copyFile` (where the fault lives).
    func cloneItem(at _: VFSPath, to _: VFSPath) throws -> Bool { false }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        if source.lastComponent == failingName, remainingFailures > 0 {
            remainingFailures -= 1
            throw makeError(source)
        }
        try inner.copyFile(at: source, to: destination, progress: progress, isCancelled: isCancelled)
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try inner.createSymbolicLink(at: destination, withDestination: target)
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        try inner.copyMetadata(at: source, to: destination)
    }

    func volumeIdentifier(for path: VFSPath) -> String? { inner.volumeIdentifier(for: path) }
}
