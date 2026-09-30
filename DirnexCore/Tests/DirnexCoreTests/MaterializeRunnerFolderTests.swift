import Foundation
import Testing

@testable import DirnexCore

/// Staging a **folder** that is not on this disk (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// Every gesture that needs real paths used to refuse one in a single sentence — *"it stands for an
/// unknown number of objects in an unknown number of requests"* — and tell the user to copy it over
/// with F5 and act on the copy. This is that remedy, performed rather than recommended: the runner
/// hands the folder to `CopyEngine`, which has walked remote trees since M5.
///
/// The backend here **routes**, because the real one does: staging reads from a server and writes to
/// this disk, so a fake that answers for only one of the two would be measuring a copy that cannot
/// happen. It is the app's `CompositeBackend` in twenty lines.
@Suite("Materialize runner ▸ a folder")
struct MaterializeRunnerFolderTests {
    private func job(_ sources: [FileEntry], into root: String) -> FileOperation {
        FileOperation(
            kind: .materialize,
            sources: sources,
            destinationDirectory: .local(root)
        )
    }

    private func names(under root: URL) throws -> [String] {
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        return found.sorted()
    }

    // MARK: - The staging itself

    @Test("a remote folder is staged whole, under its own name")
    func stagesTheTree() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore([
            "/docs/report.txt": "report",
            "/docs/notes/inner.txt": "inner"
        ])
        let backend = RoutingBackend(remote: store)

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/docs"))], into: tree.root.path),
            using: backend,
            directoryName: { "staged" }
        )

        #expect(report.succeeded)
        let staged = try #require(report.materialized?.first)
        #expect(staged.localPath == tree.root.appendingPathComponent("staged/docs").path)
        // Every file, at its own depth — the claim a one-file materialize cannot make.
        let contents = try names(under: URL(fileURLWithPath: staged.localPath))
        #expect(contents == ["inner.txt", "notes", "report.txt"])
        let inner = tree.root.appendingPathComponent("staged/docs/notes/inner.txt")
        #expect(try String(contentsOf: inner, encoding: .utf8) == "inner")
    }

    /// The cache must not adopt a tree: it decides staleness from a size and a timestamp, which for
    /// a directory answers a question nobody asked, and a staged tree can be gigabytes it would then
    /// hold for the session. The flag is how a window-scoped cache the core cannot see is told.
    @Test("a staged folder says it is one")
    func aTreeSaysSo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore(["/docs/report.txt": "report"])
        let backend = RoutingBackend(remote: store)

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/docs"))], into: tree.root.path),
            using: backend
        )
        #expect(report.materialized?.first?.isDirectory == true)
    }

    /// The narrowness control: teaching the runner about folders must not change what it does with
    /// a file, which is every other gesture in the app.
    @Test("a plain file is untouched by any of this")
    func aFileIsStillAFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore(["/report.txt": "report"])
        let backend = RoutingBackend(remote: store)

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/report.txt"))], into: tree.root.path),
            using: backend,
            directoryName: { "one" }
        )
        let file = try #require(report.materialized?.first)
        #expect(file.isDirectory == false)
        #expect(file.localPath == tree.root.appendingPathComponent("one/report.txt").path)
    }

    // MARK: - The bar

    /// A folder is the one source whose size the listing cannot state, so the denominator learns it
    /// when the folder's turn comes. What must hold is that it *ends* honest: the bar reaches its
    /// own total rather than stopping short of it, which is what a job that counted a folder as 0
    /// would do.
    @Test("the denominator grows to include the folder, and the bar reaches it")
    func theBarLearnsTheFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore([
            "/docs/a.txt": String(repeating: "a", count: 100),
            "/docs/b.txt": String(repeating: "b", count: 200)
        ])
        let backend = RoutingBackend(remote: store)
        let updates = Progress()

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/docs"))], into: tree.root.path),
            using: backend,
            onProgress: { updates.append($0) }
        )

        #expect(report.succeeded)
        let seen = updates.value
        // It opens at zero — the listing had nothing to say about a folder's weight …
        #expect(seen.first?.totalBytes == 0)
        // … and ends knowing it, with the job's own count agreeing.
        let peak = seen.map(\.totalBytes).max()
        #expect(peak == 300)
        #expect(report.completedBytes == 300)
    }

    // MARK: - When it goes wrong

    /// A partial tree is a failure, not a smaller result. An archive quietly missing three files of
    /// four hundred is the shape M24 Slice 6 had to fix once already.
    @Test("one unreadable file fails the whole folder and leaves nothing staged")
    func aPartialTreeFails() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore([
            "/docs/a.txt": "a",
            "/docs/gone.txt": "b"
        ])
        let backend = RoutingBackend(remote: store, unreadable: ["/docs/gone.txt"])

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/docs"))], into: tree.root.path),
            using: backend,
            directoryName: { "staged" }
        )

        #expect(!report.succeeded)
        #expect(report.materialized?.isEmpty ?? true)
        let failedPaths = report.failures.map(\.path.path)
        #expect(failedPaths == ["/docs"])
        // The *child's* error, carried up under the folder's name — which is what says the walk
        // went in. A folder that was never entered fails too, with `notFound` about itself, and an
        // assertion that only counted failures would read that as this test passing.
        let reason = try #require(report.failures.first?.error)
        guard case .io = reason else {
            Issue.record("expected the unreadable child's own error, got \(reason)")
            return
        }
        // Nothing half-staged for a later reader to mistake for the whole folder.
        let holder = tree.root.appendingPathComponent("staged")
        #expect(!FileManager.default.fileExists(atPath: holder.path))
    }

    @Test("a stopped staging keeps nothing")
    func cancellation() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = FakeRemoteStore(["/docs/a.txt": "a", "/docs/b.txt": "b"])
        let backend = RoutingBackend(remote: store)

        let report = MaterializeRunner.run(
            job([try store.stat(at: store.path("/docs"))], into: tree.root.path),
            using: backend,
            isCancelled: { true },
            directoryName: { "staged" }
        )

        #expect(report.wasCancelled)
        #expect(report.materialized?.isEmpty ?? true)
        #expect(
            !FileManager.default.fileExists(atPath: tree.root.appendingPathComponent("staged").path)
        )
    }
}

// MARK: - Fakes

/// Sends `.local` paths to the real local backend and everything else to the store — which is what
/// the app's `CompositeBackend` does, and what staging needs by construction: it reads from one
/// backend and writes to another.
private struct RoutingBackend: VFSBackend {
    let remote: FakeRemoteStore
    var unreadable: Set<String> = []
    private let local = LocalBackend()

    var id: VFSBackendID { .local }
    var capabilities: VFSCapabilities { [.read, .write] }

    private func backend(for path: VFSPath) -> any VFSBackend {
        path.backend == .local ? local : remote
    }

    func capabilities(for path: VFSPath) -> VFSCapabilities {
        backend(for: path).capabilities
    }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        try backend(for: path).listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try backend(for: path).stat(at: path) }

    func createDirectory(at path: VFSPath) throws { try backend(for: path).createDirectory(at: path) }

    func createFile(at path: VFSPath) throws { try backend(for: path).createFile(at: path) }

    func removeItem(at path: VFSPath) throws { try backend(for: path).removeItem(at: path) }

    func moveItem(at source: VFSPath, to destination: VFSPath) throws {
        try backend(for: source).moveItem(at: source, to: destination)
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard !unreadable.contains(source.path) else { throw VFSError.io(path: source, code: 5) }
        try remote.copyFile(
            at: source,
            to: destination,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        try local.createSymbolicLink(at: destination, withDestination: target)
    }
}

/// What a `@Sendable` progress closure reported.
private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [OperationProgress] = []

    var value: [OperationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }

    func append(_ update: OperationProgress) {
        lock.lock()
        defer { lock.unlock() }
        updates.append(update)
    }
}
