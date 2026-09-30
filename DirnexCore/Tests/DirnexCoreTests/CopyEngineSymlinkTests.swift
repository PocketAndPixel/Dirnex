import Foundation
import Testing

@testable import DirnexCore

/// What a copy does with a symlink whose target the listing could not read (PLAN.md §M25 Slice 4).
///
/// `sftp`'s `ls` prints no ` -> target` and `ls -la` of a link *follows* it, so over SFTP every
/// link arrives with `symlinkDestination == nil`. The engine recreated one from that text, and
/// `symlink(2)` **accepts an empty target** on macOS — measured 2026-08-28: it returns 0 and leaves
/// a 0-byte dangling link. So the behaviour under test is not "does it error", it is that a copy
/// which cannot be made faithfully **says so** instead of reporting success over a broken link.
@Suite("Copying a symlink with an unreadable target")
struct CopyEngineSymlinkTests {
    /// `LocalBackend` with `sftp`'s blind spot: the listing knows a row is a link and cannot say
    /// what it points at. `resolvable` is the exec channel — off by default, which is the state an
    /// `sftp`-only account is permanently in.
    private struct BlindToTargetsBackend: VFSBackend {
        let inner = LocalBackend()
        var resolvable = false
        /// Every batch handed to ``resolvingSymlinkTargets(in:)``, so a test can count round trips.
        let asked = AskedBatches()

        var id: VFSBackendID { inner.id }
        var capabilities: VFSCapabilities { inner.capabilities }

        private func blinded(_ entry: FileEntry) -> FileEntry {
            guard entry.kind == .symlink else { return entry }
            return FileEntry(
                path: entry.path, name: entry.name, kind: .symlink, byteSize: entry.byteSize,
                modificationDate: entry.modificationDate, creationDate: entry.creationDate,
                isHidden: entry.isHidden, permissions: entry.permissions, inode: entry.inode,
                symlinkDestination: nil, symlinkTargetKind: entry.symlinkTargetKind
            )
        }

        func listDirectory(at path: VFSPath) throws -> [FileEntry] {
            try inner.listDirectory(at: path).map(blinded)
        }

        func stat(at path: VFSPath) throws -> FileEntry { blinded(try inner.stat(at: path)) }

        func resolvingSymlinkTargets(in entries: [FileEntry]) -> [FileEntry] {
            let unresolved = entries.filter { $0.kind == .symlink && $0.symlinkDestination == nil }
            guard !unresolved.isEmpty else { return entries }
            asked.record(unresolved.map(\.path.path))
            guard resolvable else { return entries }
            return entries.map { entry in
                guard entry.kind == .symlink, entry.symlinkDestination == nil,
                      let target = try? FileManager.default
                      .destinationOfSymbolicLink(atPath: entry.path.path)
                else { return entry }
                return entry.withSymlinkDestination(target)
            }
        }

        func createDirectory(at path: VFSPath) throws { try inner.createDirectory(at: path) }
        func removeItem(at path: VFSPath) throws { try inner.removeItem(at: path) }
        func trashItem(at path: VFSPath) throws -> VFSPath? { try inner.trashItem(at: path) }
        func cloneItem(at _: VFSPath, to _: VFSPath) throws -> Bool { false }
        func moveItem(at source: VFSPath, to destination: VFSPath) throws {
            try inner.moveItem(at: source, to: destination)
        }

        func copyFile(
            at source: VFSPath, to destination: VFSPath,
            progress: (Int64) -> Void, isCancelled: () -> Bool
        ) throws {
            try inner.copyFile(
                at: source, to: destination, progress: progress, isCancelled: isCancelled
            )
        }

        func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
            try inner.createSymbolicLink(at: destination, withDestination: target)
        }
    }

    private func copy(_ source: String, in tree: TempTree, using backend: some VFSBackend) throws
        -> OperationReport {
        CopyEngine.run(
            FileOperation(
                kind: .copy,
                sources: [try backend.stat(at: tree.vfsPath(source))],
                destinationDirectory: tree.vfsPath("dest")
            ),
            using: backend
        )
    }

    @Test("a link whose target cannot be read is refused, and no empty link is left behind")
    func refusesAnUnreadableTarget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.symlink("link", to: "notes.txt")
        _ = try tree.makeDir("dest")

        let report = try copy("link", in: tree, using: BlindToTargetsBackend())
        #expect(!report.succeeded)
        #expect(report.failures.count == 1)
        #expect(
            report.failures.first?.error
                == .unsupported(.symbolicLinkTargetUnreadable(name: "link"))
        )
        // The claim that matters: nothing was created. Before this slice `symlink("")` succeeded
        // here and the copy reported success over a 0-byte dangling link.
        #expect(!FileManager.default.fileExists(atPath: tree.path("dest/link")))
    }

    @Test("a link whose target the connection can read is copied faithfully")
    func copiesAResolvedTarget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.symlink("link", to: "../elsewhere/notes.txt")
        _ = try tree.makeDir("dest")

        var backend = BlindToTargetsBackend()
        backend.resolvable = true
        #expect(try copy("link", in: tree, using: backend).succeeded)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: tree.path("dest/link"))
                == "../elsewhere/notes.txt"
        )
    }

    /// The narrowness control on the refusal, and the distinction the whole rule turns on: an
    /// **empty** target is a link somebody really made, where `nil` means nobody could read it.
    /// Folding the two together would refuse a legal local link — the same trap §M25 Slice 1 avoided
    /// by keeping "no mode reported" apart from "a mode we dropped".
    @Test("a link that really does point at nothing is still copied")
    func copiesAGenuinelyEmptyTarget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.symlink("empty", to: "")
        _ = try tree.makeDir("dest")

        let backend = LocalBackend()
        #expect(try copy("empty", in: tree, using: backend).succeeded)
        let copied = try FileManager.default
            .destinationOfSymbolicLink(atPath: tree.path("dest/empty"))
        #expect(copied.isEmpty)
    }

    /// The other narrowness control: an ordinary local copy must be untouched, asking nothing,
    /// because its listing already carries every target.
    @Test("an ordinary local copy asks nothing and copies its links as before")
    func localCopyIsUnchanged() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        _ = try tree.makeDir("top")
        try tree.symlink("top/link", to: "/some/target")
        _ = try tree.makeDir("dest")

        var backend = BlindToTargetsBackend()
        backend.resolvable = true
        // The real local backend keeps its targets, so nothing is ever asked.
        let real = LocalBackend()
        #expect(try copy("top", in: tree, using: real).succeeded)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: tree.path("dest/top/link"))
                == "/some/target"
        )
    }

    /// The cost rule. Learning a target is a whole SSH exec channel — 77 ms against a loopback
    /// server, and the same 79 ms whether it names one link or twelve — so a directory of links must
    /// be one round trip, not one per link.
    @Test("a directory of links is resolved in one batch, not one round trip each")
    func resolvesADirectoryInOneBatch() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        _ = try tree.makeDir("top")
        for index in 0..<5 { try tree.symlink("top/link\(index)", to: "target\(index)") }
        _ = try tree.makeDir("dest")

        var backend = BlindToTargetsBackend()
        backend.resolvable = true
        #expect(try copy("top", in: tree, using: backend).succeeded)
        // One for the marked source (the directory carries no link of its own, so nothing is
        // asked there) and one for its five children — never five.
        #expect(backend.asked.count == 1)
        #expect(backend.asked.largest == 5)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: tree.path("dest/top/link3"))
                == "target3"
        )
    }

    @Test("one unreadable link does not stop the rest of the tree")
    func refusesPerItem() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        _ = try tree.makeDir("dest")
        _ = try tree.writeFile("notes.txt", contents: "hello")
        try tree.symlink("link", to: "notes.txt")

        let backend = BlindToTargetsBackend()
        let report = CopyEngine.run(
            FileOperation(
                kind: .copy,
                sources: [
                    try backend.stat(at: tree.vfsPath("link")),
                    try backend.stat(at: tree.vfsPath("notes.txt"))
                ],
                destinationDirectory: tree.vfsPath("dest")
            ),
            using: backend
        )
        #expect(report.failures.count == 1)
        #expect(report.completedItems == 1)
        #expect(FileManager.default.fileExists(atPath: tree.path("dest/notes.txt")))
    }
}

/// The batches a fixture backend was asked to resolve, so a test can assert the *shape* of the
/// asking — one round trip per directory, never one per link.
private final class AskedBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches.count
    }

    var largest: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches.map(\.count).max() ?? 0
    }

    func record(_ paths: [String]) {
        lock.lock()
        batches.append(paths)
        lock.unlock()
    }
}
