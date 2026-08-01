import Foundation
import Testing

@testable import DirnexCore

/// The scratch tree and the small vocabulary the recursive-apply suites share (PLAN.md §M14
/// Slice 4).
///
/// Shared rather than duplicated because the two suites are the same operation seen from two sides —
/// what it writes (`AttributeApplyRunnerTests`) and what it leaves behind
/// (`AttributeApplyReportTests`) — and a second copy of "what the tree looks like" is how the two
/// stop testing the same thing.
struct AttributeApplyFixture {
    let backend = LocalBackend()
    let tree: TempTree

    /// A three-level tree: `a.txt`, `sub/b.txt`, `sub/deep/c.txt` — six items counting the
    /// directories, which is the number every count assertion is drawn from.
    init() throws {
        tree = try TempTree()
        try tree.makeDir("sub/deep")
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("sub/b.txt", contents: "b")
        try tree.writeFile("sub/deep/c.txt", contents: "c")
    }

    func cleanup() {
        // Anything a test locked or made unwalkable has to be reopened, or the tree cannot be
        // removed — the one piece of teardown this operation genuinely needs.
        for relative in ["sub/deep", "sub", ""] {
            _ = chflags(tree.path(relative), 0)
            _ = chmod(tree.path(relative), 0o755)
        }
        tree.cleanup()
    }

    // MARK: - Reading back

    func entry(_ relative: String = "") throws -> FileEntry {
        try backend.stat(at: tree.vfsPath(relative))
    }

    func mode(_ relative: String = "") throws -> UInt16 {
        try FileAttributeIO.read(at: tree.vfsPath(relative)).attributes.permissions.rawValue
    }

    func flags(_ relative: String = "") throws -> BSDFileFlags {
        try FileAttributeIO.read(at: tree.vfsPath(relative)).attributes.flags
    }

    func accessControlList(_ relative: String = "") throws -> AccessControlList {
        try AccessControlListIO.read(at: tree.vfsPath(relative))
    }

    /// Give a directory its owner read/search bits back, so a *test* can look inside it again.
    ///
    /// Needed only after a run that writes a mode with no `x`, and needing it is the point: at that
    /// moment nothing — not the test, not `ls`, not the run itself — can resolve a path through that
    /// directory. Reopening one level at a time is how such a test's assertions walk down.
    func restoreTraversal(_ relative: String = "") {
        var stats = Darwin.stat()
        #expect(lstat(tree.path(relative), &stats) == 0)
        #expect(chmod(tree.path(relative), stats.st_mode | S_IXUSR | S_IRUSR) == 0)
    }

    // MARK: - Building a job

    func patch(mode: UInt16) -> AttributePatch {
        var patch = AttributePatch()
        patch.permissionMask = POSIXPermissions(rawValue: 0o7777)
        patch.permissionValues = POSIXPermissions(rawValue: mode)
        return patch
    }

    func patch(setting flags: BSDFileFlags) -> AttributePatch {
        var patch = AttributePatch()
        patch.flagsToSet = flags
        return patch
    }

    /// The running user as an ACL subject — a real GUID from the OS, so what a test writes is what
    /// `acl_from_text` accepts back.
    static func currentUserSubject() -> ACLSubject? {
        let uid = getuid()
        guard let name = IdentityDirectory.userName(for: uid) else { return nil }
        return ACLIdentity.subject(for: IdentityRecord(name: name, numericID: uid), kind: .user)
    }

    // MARK: - Running

    func run(
        _ job: AttributeApplyJob,
        sources: [String] = [""],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> OperationReport {
        AttributeApplyRunner.run(
            job,
            sources: try sources.map { try entry($0) },
            using: backend,
            isCancelled: isCancelled
        )
    }

    func outcome(_ report: OperationReport) throws -> AttributeApplyOutcome {
        try #require(report.attributeApply)
    }
}

/// A thread-safe call counter for a cancellation hook, which a runner may poll from any thread.
final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
