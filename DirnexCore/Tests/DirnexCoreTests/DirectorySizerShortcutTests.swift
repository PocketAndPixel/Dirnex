import Foundation
import Testing

@testable import DirnexCore

/// The sizer asking the backend for a whole subtree instead of walking it a directory at a time
/// (PLAN.md ▸ Still open, "Size bars are local-only …").
///
/// ``VFSBackend/subtreeListing(at:isCancelled:)`` shipped at M22 for search and was adopted by
/// ``DirectorySync`` at M25; the sizer was the remaining consumer asking for everything the
/// expensive way. Measured against a real `sshd` over 136 directories: **137 sessions and 19.24 s**
/// walking, **1 session and 0.156 s** through the shortcut, totals identical to the byte.
///
/// What matters here is that the two routes are **interchangeable**, so every test compares the
/// shortcut against the walk over the same tree rather than against a number written down twice.
@Suite("DirectorySizer subtree shortcut")
struct DirectorySizerShortcutTests {
    /// A tree with two levels and a symlink, so the rules the two routes must agree about are all
    /// present: files carry bytes, directories carry none of their own, and a symlink counts as its
    /// own link size rather than its target's.
    private func tree() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("docs")
        try tree.makeDir("docs/api")
        try tree.makeDir("build")
        try tree.writeFile("top.bin", bytes: 5)
        try tree.writeFile("docs/guide.bin", bytes: 7)
        try tree.writeFile("docs/api/ref.bin", bytes: 11)
        try tree.writeFile("build/out.bin", bytes: 1000)
        return tree
    }

    @Test("a backend that can hand over its subtree is not walked")
    func shortcutReplacesTheWalk() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(isComplete: true)

        let measured = try DirectorySizer.measure(of: tree.vfsPath(), using: backend)

        #expect(measured.bytes == 1023)
        // One request, whatever the tree holds — the whole point, and the number a set's allowance
        // is charged.
        #expect(measured.requestsMade == 1)
        #expect(backend.listedPaths.isEmpty, "nothing was listed a directory at a time")
        #expect(backend.subtreeRequests == 1)
    }

    /// The claim that makes the shortcut adoptable at all: the same tree, both ways, same answer.
    /// Written as a comparison rather than against 1023 so it cannot be satisfied by two matching
    /// mistakes.
    @Test("the shortcut and the walk agree, to the byte")
    func routesAgree() throws {
        let tree = try tree()
        defer { tree.cleanup() }

        let shortcut = try DirectorySizer.measure(
            of: tree.vfsPath(), using: SubtreeSizeBackend(isComplete: true)
        )
        let walked = try DirectorySizer.measure(
            of: tree.vfsPath(), using: SubtreeSizeBackend(isComplete: true, offersShortcut: false)
        )

        #expect(shortcut.bytes == walked.bytes)
        // And they are *not* the same cost, which is what says the first one took the shortcut.
        #expect(shortcut.requestsMade == 1)
        #expect(walked.requestsMade == 4, "the root plus docs, docs/api and build")
    }

    /// SFTP caps its own output, because a `find` over a home directory would be megabytes down one
    /// channel. A capped slice summed as a total is a confident wrong number — so it is refused and
    /// the walk answers instead.
    @Test("an incomplete subtree is refused and the walk answers")
    func incompleteFallsBackToTheWalk() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(isComplete: false)

        let measured = try DirectorySizer.measure(of: tree.vfsPath(), using: backend)

        #expect(backend.subtreeRequests == 1, "it was asked")
        #expect(measured.bytes == 1023, "and the capped slice was not what answered")
        #expect(!backend.listedPaths.isEmpty, "the walk ran")
        #expect(measured.requestsMade == 4)
    }

    /// A shortcut that fails means only that the shortcut is unavailable — the walk standing behind
    /// it will surface a real failure with a real error if there is one. `SFTPBackend` already
    /// swallows its own transport failures for this reason; this covers a backend that does not.
    @Test("a throwing shortcut falls back to the walk")
    func throwingShortcutFallsBack() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(
            isComplete: true, shortcutError: VFSError.io(path: tree.vfsPath(), code: 5)
        )

        let measured = try DirectorySizer.measure(of: tree.vfsPath(), using: backend)

        #expect(measured.bytes == 1023)
        #expect(measured.requestsMade == 4)
    }

    /// Cancellation is the caller's own instruction and must travel, where every other failure is
    /// absorbed. Without this a Stop pressed during the shortcut would be answered by a full walk.
    @Test("cancellation from the shortcut is not absorbed")
    func cancellationTravels() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(isComplete: true, shortcutError: CancellationError())

        #expect(throws: CancellationError.self) {
            try DirectorySizer.measure(of: tree.vfsPath(), using: backend)
        }
        #expect(backend.listedPaths.isEmpty, "and no walk was started instead")
    }

    /// The rule a flat listing does not get for free: a walk never pushes an excluded directory, so
    /// nothing beneath one is ever seen, while the listing contains those descendants and they have
    /// to be dropped by ancestry. Asserted as agreement with the walk, which is the only definition
    /// of right there is.
    @Test("an excluded directory takes its subtree with it, both ways")
    func exclusionPrunesTheSubtree() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let excluded = tree.vfsPath("docs")
        let prune: (VFSPath) -> Bool = { $0 == excluded }

        let shortcut = try DirectorySizer.measure(
            of: tree.vfsPath(), using: SubtreeSizeBackend(isComplete: true), excluding: prune
        )
        let walked = try DirectorySizer.measure(
            of: tree.vfsPath(),
            using: SubtreeSizeBackend(isComplete: true, offersShortcut: false),
            excluding: prune
        )

        // 1005: the top-level file and `build`, with `docs/guide.bin` *and* the nested
        // `docs/api/ref.bin` gone — the nested one is what a per-entry filter would have kept.
        #expect(shortcut.bytes == 1005)
        #expect(shortcut.bytes == walked.bytes)
    }

    /// A set whose allowance is spent must stop spending, and the shortcut is a request like any
    /// other — one per remaining row is exactly the runaway a set allowance exists to prevent.
    @Test("an exhausted allowance refuses the shortcut too")
    func spentAllowanceRefusesEverything() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(isComplete: true)

        #expect(throws: DirectorySizeBudgetExceeded.self) {
            try DirectorySizer.measure(
                of: tree.vfsPath(),
                using: backend,
                budget: DirectorySizeBudget(directoryLimit: 0)
            )
        }
        #expect(backend.subtreeRequests == 0, "nothing was asked of the backend at all")
        #expect(backend.listedPaths.isEmpty)
    }

    /// `size` is `measure` with the cost dropped, so the pre-existing callers cannot drift from it.
    @Test("size and measure report the same bytes")
    func sizeWrapsMeasure() throws {
        let tree = try tree()
        defer { tree.cleanup() }
        let backend = SubtreeSizeBackend(isComplete: true)

        let bytes = try DirectorySizer.size(of: tree.vfsPath(), using: backend)

        #expect(bytes == 1023)
    }
}

/// A local backend that can also hand over a whole subtree, standing in for SFTP's exec walk and
/// S3's delimiter-less listing, counting both routes so a test can assert which one ran.
///
/// A second copy of `DirectorySyncSubtreeTests`' fake, which is `private` to that file — Swift's
/// `private` does not cross files (docs/NOTES.md ▸ file splitting), and widening it would export a
/// test helper from a suite that does not own this question.
private final class SubtreeSizeBackend: VFSBackend, @unchecked Sendable {
    private let inner = LocalBackend()
    private let lock = NSLock()
    private let isComplete: Bool
    private let offersShortcut: Bool
    private let shortcutError: (any Error)?
    private var listed: [VFSPath] = []
    private var subtrees = 0

    init(isComplete: Bool, offersShortcut: Bool = true, shortcutError: (any Error)? = nil) {
        self.isComplete = isComplete
        self.offersShortcut = offersShortcut
        self.shortcutError = shortcutError
    }

    var listedPaths: [VFSPath] {
        lock.lock()
        defer { lock.unlock() }
        return listed
    }

    var subtreeRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return subtrees
    }

    var id: VFSBackendID { inner.id }
    var capabilities: VFSCapabilities { inner.capabilities }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] {
        lock.lock()
        listed.append(path)
        lock.unlock()
        return try inner.listDirectory(at: path)
    }

    func stat(at path: VFSPath) throws -> FileEntry { try inner.stat(at: path) }

    func subtreeListing(at path: VFSPath, isCancelled: () -> Bool) throws -> VFSSubtreeListing? {
        if let shortcutError { throw shortcutError }
        lock.lock()
        subtrees += 1
        lock.unlock()
        guard offersShortcut else { return nil }
        // Gathered through `inner`, not through `self`, so `listedPaths` counts only what the sizer
        // asked for — the assertion that separates the two routes.
        var entries: [FileEntry] = []
        var queue = [path]
        while let directory = queue.popLast() {
            for entry in try inner.listDirectory(at: directory) {
                entries.append(entry)
                if entry.isDirectory { queue.append(entry.path) }
            }
        }
        // A capped answer is genuinely **short**, the way SFTP's row limit truncates a real one —
        // not the whole tree wearing a flag, or a control over the completeness guard could pass by
        // reading the same rows from a different place.
        guard isComplete else {
            return VFSSubtreeListing(entries: Array(entries.prefix(1)), isComplete: false)
        }
        return VFSSubtreeListing(entries: entries, isComplete: true)
    }
}
