import Foundation
import Testing

@testable import DirnexCore

/// Multi-rename over a selection spanning several directories — the tree's cross-level batch
/// (PLAN.md §M15). The flat `MultiRenameTests` cover one directory; these pin that a bystander
/// check and a duplicate check are each scoped to the folder an item actually lands in, so a
/// tree batch neither blocks a legitimate rename nor silently clobbers a file in a *different*
/// folder it was never told about.
@Suite("MultiRename across directories")
struct MultiRenameDirectoryTests {
    private func entry(_ name: String, in directory: String) -> FileEntry {
        FileEntry(
            path: .local("\(directory)/\(name)"),
            name: name,
            kind: .file,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 0),
            creationDate: Date(timeIntervalSince1970: 0),
            isHidden: false,
            permissions: 0o644,
            inode: 0
        )
    }

    @Test("two items in different folders may take the same name without clashing")
    func sameNameDifferentDirectoriesIsNotDuplicate() {
        // /a/x.txt and /b/x.txt both become y.txt. They land in different folders, so neither is a
        // duplicate of the other.
        let items = [entry("x.txt", in: "/a"), entry("x.txt", in: "/b")]
        let plan = MultiRename.plan(
            for: items,
            spec: RenameSpec(nameTemplate: "y"),
            existingNamesByDirectory: [
                .local("/a"): ["x.txt"],
                .local("/b"): ["x.txt"]
            ]
        )
        #expect(plan.map(\.newName) == ["y.txt", "y.txt"])
        let allApply = plan.allSatisfy(\.willRename)
        #expect(allApply)
    }

    @Test("two items in the same folder resolving to one name are still duplicates")
    func sameNameSameDirectoryIsStillDuplicate() {
        let items = [entry("a.txt", in: "/a"), entry("b.txt", in: "/a")]
        let plan = MultiRename.plan(
            for: items,
            spec: RenameSpec(nameTemplate: "same"),
            existingNamesByDirectory: [.local("/a"): ["a.txt", "b.txt"]]
        )
        let allDuplicates = plan.allSatisfy { $0.status == .duplicate }
        #expect(allDuplicates)
    }

    @Test("a bystander only collides in the item's own folder")
    func collisionIsScopedToDirectory() {
        // "taken.txt" exists in /b but not /a; renaming /a/a.txt onto it is a clean rename — the
        // old single-set planner would have blocked it, or (worse, once the destination followed
        // the item's own directory) silently overwritten a real bystander in /a it never heard of.
        let clean = MultiRename.plan(
            for: [entry("a.txt", in: "/a")],
            spec: RenameSpec(nameTemplate: "taken"),
            existingNamesByDirectory: [
                .local("/a"): ["a.txt"],
                .local("/b"): ["taken.txt"]
            ]
        )
        #expect(clean[0].status == .rename)

        // The same name existing in the item's *own* folder is a genuine collision.
        let colliding = MultiRename.plan(
            for: [entry("a.txt", in: "/a")],
            spec: RenameSpec(nameTemplate: "taken"),
            existingNamesByDirectory: [.local("/a"): ["a.txt", "taken.txt"]]
        )
        #expect(colliding[0].status == .collision)
    }

    @Test("the flat existingNames overload scopes bystanders to each item's directory")
    func flatOverloadIsDirectoryScoped() {
        // The convenience overload attributes one name set to whichever directories the items are
        // in, so it must not read the set as one shared namespace: /a/x.txt and /b/x.txt both to
        // y.txt is clean, since "y.txt" is in neither folder.
        let items = [entry("x.txt", in: "/a"), entry("x.txt", in: "/b")]
        let plan = MultiRename.plan(
            for: items,
            spec: RenameSpec(nameTemplate: "y"),
            existingNames: ["x.txt"]
        )
        let allApply = plan.allSatisfy(\.willRename)
        #expect(allApply)
    }
}
