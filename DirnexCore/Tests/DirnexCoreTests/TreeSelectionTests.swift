import Foundation
import Testing

@testable import DirnexCore

/// The two operation semantics settled before M15 Slice 4 opened: what F5/F6 do with marks spanning
/// levels, and what F8 does when an ancestor and its descendant are both marked (PLAN.md §M15).
@Suite("TreeSelection")
struct TreeSelectionTests {
    private let root = VFSPath.local("/root")

    private func entry(
        _ path: String,
        kind: FileEntry.Kind = .file
    ) -> FileEntry {
        let vfsPath = VFSPath.local(path)
        return FileEntry(
            path: vfsPath,
            name: vfsPath.lastComponent,
            kind: kind,
            byteSize: kind == .directory ? 0 : 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    private func dir(_ path: String) -> FileEntry {
        entry(path, kind: .directory)
    }

    // MARK: - Grouping (F5/F6 across levels)

    @Test("A selection at the tree's own level is one group with no relative path")
    func flatSelectionIsOneGroup() {
        let sources = [entry("/root/a.txt"), entry("/root/b.txt")]
        let groups = TreeSelection.transferGroups(sources, relativeTo: root)
        #expect(groups.count == 1)
        #expect(groups[0].relativeComponents == [])
        #expect(groups[0].sources.map(\.name) == ["a.txt", "b.txt"])
    }

    @Test("Marks spanning levels group by their path relative to the tree root")
    func nestedSelectionPreservesRelativePaths() {
        let sources = [
            entry("/root/top.txt"),
            entry("/root/Alpha/apple.txt"),
            entry("/root/Alpha/Nested/deep.txt"),
            entry("/root/Beta/pear.txt")
        ]
        let groups = TreeSelection.transferGroups(sources, relativeTo: root)
        #expect(groups.map(\.relativeComponents) == [
            [],
            ["Alpha"],
            ["Beta"],
            ["Alpha", "Nested"]
        ])
        #expect(groups.map { $0.sources.map(\.name) } == [
            ["top.txt"],
            ["apple.txt"],
            ["pear.txt"],
            ["deep.txt"]
        ])
    }

    @Test("Two files of the same name in different folders stay apart")
    func sameNameInTwoFoldersDoesNotCollide() {
        let sources = [entry("/root/Alpha/x.jpg"), entry("/root/Beta/x.jpg")]
        let groups = TreeSelection.transferGroups(sources, relativeTo: root)
        let destinations = groups.map { $0.destination(under: .local("/dest")).path }
        #expect(destinations == ["/dest/Alpha", "/dest/Beta"])
    }

    @Test("Sources in one directory keep their marked order")
    func groupPreservesRowOrder() {
        let sources = [
            entry("/root/Alpha/c.txt"),
            entry("/root/Alpha/a.txt"),
            entry("/root/Alpha/b.txt")
        ]
        let groups = TreeSelection.transferGroups(sources, relativeTo: root)
        #expect(groups.count == 1)
        #expect(groups[0].sources.map(\.name) == ["c.txt", "a.txt", "b.txt"])
    }

    @Test("Groups come back shallowest-first, every one after the groups that contain it")
    func groupsAreOrderedParentsFirst() {
        let sources = [
            entry("/root/a/b/c/deep.txt"),
            entry("/root/a/b/mid.txt"),
            entry("/root/a/shallow.txt")
        ]
        let groups = TreeSelection.transferGroups(sources, relativeTo: root)
        #expect(groups.map(\.relativeComponents) == [["a"], ["a", "b"], ["a", "b", "c"]])
    }

    @Test("A marked directory lands beside its own name, not inside it")
    func markedDirectoryLandsAtItsParent() {
        let groups = TreeSelection.transferGroups([dir("/root/Alpha/Nested")], relativeTo: root)
        #expect(groups.count == 1)
        #expect(groups[0].destination(under: .local("/dest")).path == "/dest/Alpha")
    }

    @Test("A root at / needs no special casing")
    func rootOfBackendGroupsCorrectly() {
        let groups = TreeSelection.transferGroups(
            [entry("/Users/oleg/x.txt")],
            relativeTo: .local("/")
        )
        #expect(groups[0].relativeComponents == ["Users", "oleg"])
    }

    @Test("An item outside the root lands at the top level rather than being dropped")
    func itemOutsideRootIsKept() {
        let groups = TreeSelection.transferGroups([entry("/elsewhere/x.txt")], relativeTo: root)
        #expect(groups.count == 1)
        #expect(groups[0].relativeComponents == [])
        #expect(groups[0].sources.map(\.name) == ["x.txt"])
    }

    @Test("A same-named path in another backend is not treated as being under the root")
    func otherBackendIsNotUnderRoot() {
        let path = VFSPath(backend: .trash, path: "/root/Alpha/x.txt")
        let source = FileEntry(
            path: path,
            name: "x.txt",
            kind: .file,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
        let groups = TreeSelection.transferGroups([source], relativeTo: root)
        #expect(groups[0].relativeComponents == [])
    }

    @Test("An empty selection produces no groups")
    func emptySelectionProducesNoGroups() {
        #expect(TreeSelection.transferGroups([], relativeTo: root).isEmpty)
    }

    @Test("A group's destination is its components appended to the operation's destination")
    func destinationAppendsComponents() {
        let group = TreeTransferGroup(relativeComponents: ["Alpha", "Nested"], sources: [])
        #expect(group.destination(under: .local("/dest")).path == "/dest/Alpha/Nested")
        #expect(group.destination(under: .local("/dest")).backend == .local)
        let flat = TreeTransferGroup(relativeComponents: [], sources: [])
        #expect(flat.destination(under: .local("/dest")) == .local("/dest"))
    }

    // MARK: - Dedup (F8, and the recursive half of F5/F6)

    @Test("A descendant of a marked folder is dropped, keeping the ancestor")
    func descendantOfMarkedFolderIsDropped() {
        let sources = [
            dir("/root/Alpha"),
            entry("/root/Alpha/apple.txt"),
            entry("/root/Alpha/Nested/deep.txt"),
            entry("/root/top.txt")
        ]
        let kept = TreeSelection.withoutNestedItems(sources)
        #expect(kept.map(\.name) == ["Alpha", "top.txt"])
    }

    @Test("Only the outermost survives a three-level chain")
    func onlyOutermostSurvivesChain() {
        let sources = [
            dir("/root/a"),
            dir("/root/a/b"),
            dir("/root/a/b/c")
        ]
        #expect(TreeSelection.withoutNestedItems(sources).map(\.path.path) == ["/root/a"])
    }

    @Test("A dedupe keeps the given order")
    func dedupePreservesOrder() {
        let sources = [
            entry("/root/z.txt"),
            dir("/root/Alpha"),
            entry("/root/Alpha/apple.txt"),
            entry("/root/a.txt")
        ]
        #expect(TreeSelection.withoutNestedItems(sources).map(\.name) == ["z.txt", "Alpha", "a.txt"])
    }

    @Test("Siblings are untouched — a list-mode selection is never reduced")
    func siblingsSurvive() {
        let sources = [entry("/root/a.txt"), entry("/root/b.txt"), dir("/root/Alpha")]
        #expect(TreeSelection.withoutNestedItems(sources).count == 3)
    }

    @Test("A folder whose name prefixes another is not its ancestor")
    func namePrefixIsNotContainment() {
        let sources = [dir("/root/Alpha"), entry("/root/AlphaBeta/x.txt")]
        #expect(TreeSelection.withoutNestedItems(sources).count == 2)
    }

    @Test("Containment is per backend")
    func containmentIsPerBackend() {
        let localDir = dir("/root/Alpha")
        let remote = VFSPath(backend: .trash, path: "/root/Alpha/x.txt")
        let remoteEntry = FileEntry(
            path: remote,
            name: "x.txt",
            kind: .file,
            byteSize: 1,
            modificationDate: Date(timeIntervalSince1970: 1_000_000),
            creationDate: Date(timeIntervalSince1970: 1_000_000),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
        #expect(TreeSelection.withoutNestedItems([localDir, remoteEntry]).count == 2)
    }

    @Test("Deduping then grouping leaves the ancestor's own relative path")
    func dedupeComposesWithGrouping() {
        let sources = [
            dir("/root/Alpha/Nested"),
            entry("/root/Alpha/Nested/deep.txt")
        ]
        let groups = TreeSelection.transferGroups(
            TreeSelection.withoutNestedItems(sources),
            relativeTo: root
        )
        #expect(groups.count == 1)
        #expect(groups[0].relativeComponents == ["Alpha"])
        #expect(groups[0].sources.map(\.name) == ["Nested"])
    }
}
