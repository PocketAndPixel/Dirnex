import Foundation
import Testing

@testable import DirnexCore

/// The pure rules a recursive attributes apply runs on (PLAN.md §M14 Slice 4).
///
/// The ordering suite is the one that matters. Post-order is not a preference — probed 2026-08-01,
/// applying to a directory before its children makes every child path fail to resolve, and having
/// gathered the paths first does not save it. A regression here does not throw; it "succeeds" while
/// leaving most of a tree untouched, so the order is pinned directly.
@Suite("AttributeApplyScope")
struct AttributeApplyScopeTests {
    // MARK: - Target filter

    @Test("Everything includes every kind")
    func everythingIncludesAll() {
        for kind in [FileEntry.Kind.file, .directory, .symlink, .other] {
            #expect(AttributeApplyScope.includes(kind, target: .everything))
        }
    }

    @Test("Files only excludes directories, and a symlink counts as a file")
    func filesOnly() {
        #expect(AttributeApplyScope.includes(.file, target: .filesOnly))
        #expect(AttributeApplyScope.includes(.symlink, target: .filesOnly))
        #expect(AttributeApplyScope.includes(.other, target: .filesOnly))
        #expect(!AttributeApplyScope.includes(.directory, target: .filesOnly))
    }

    @Test("Folders only takes directories and nothing else")
    func foldersOnly() {
        #expect(AttributeApplyScope.includes(.directory, target: .foldersOnly))
        #expect(!AttributeApplyScope.includes(.file, target: .foldersOnly))
        #expect(!AttributeApplyScope.includes(.symlink, target: .foldersOnly))
    }

    // MARK: - Descending

    @Test("Only a real directory is descended into — never a symlink to one")
    func descendsIntoDirectoriesOnly() {
        #expect(AttributeApplyScope.shouldDescend(into: entry("/a", kind: .directory)))
        #expect(!AttributeApplyScope.shouldDescend(into: entry("/a", kind: .file)))
        // A link to a directory has kind `.symlink`, which is what keeps a cycle finite.
        #expect(!AttributeApplyScope.shouldDescend(into: entry(
            "/a", kind: .symlink, targetKind: .directory
        )))
    }

    // MARK: - Order

    @Test("Application order is deepest-first, so a directory is written after its children")
    func deepestFirst() {
        let ordered = AttributeApplyScope.applicationOrder(of: [
            .local("/t"),
            .local("/t/a.txt"),
            .local("/t/sub"),
            .local("/t/sub/deep"),
            .local("/t/sub/deep/c.txt")
        ])
        #expect(ordered.map(\.path) == [
            "/t/sub/deep/c.txt",
            "/t/sub/deep",
            "/t/a.txt",
            "/t/sub",
            "/t"
        ])
    }

    @Test("Every parent comes after every one of its own descendants")
    func parentsFollowDescendants() {
        let paths: [VFSPath] = [
            .local("/t"), .local("/t/x"), .local("/t/x/y"), .local("/t/x/y/z.txt"),
            .local("/t/b.txt"), .local("/t/x/w.txt")
        ]
        let ordered = AttributeApplyScope.applicationOrder(of: paths)
        for (index, path) in ordered.enumerated() {
            let descendantsAfter = ordered.dropFirst(index + 1).filter {
                $0.path.hasPrefix(path.path + "/")
            }
            #expect(descendantsAfter.isEmpty, "\(path.path) was applied before its own descendants")
        }
    }

    @Test("Items at the same depth keep the walk's order, so a re-run applies identically")
    func stableWithinADepth() {
        let ordered = AttributeApplyScope.applicationOrder(of: [
            .local("/t/c"), .local("/t/a"), .local("/t/b")
        ])
        #expect(ordered.map(\.path) == ["/t/c", "/t/a", "/t/b"])
    }

    @Test("An empty list orders to nothing rather than trapping")
    func empty() {
        #expect(AttributeApplyScope.applicationOrder(of: []).isEmpty)
    }

    // MARK: - Helper

    private func entry(
        _ path: String,
        kind: FileEntry.Kind,
        targetKind: FileEntry.Kind? = nil
    ) -> FileEntry {
        FileEntry(
            path: .local(path),
            name: (path as NSString).lastPathComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(),
            creationDate: Date(),
            isHidden: false,
            permissions: 0o755,
            ownerID: 501,
            groupID: 20,
            flags: 0,
            inode: 1,
            symlinkDestination: kind == .symlink ? "/elsewhere" : nil,
            symlinkTargetKind: targetKind
        )
    }
}
