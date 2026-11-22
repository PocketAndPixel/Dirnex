import Foundation
import Testing

@testable import DirnexCore

/// Reading a file on this Mac for a walk where Spotlight does not index (PLAN.md §M40 Slice 3),
/// against real files, since what is under test is what macOS hands back for them.
@Suite("Local search inspector")
struct LocalSearchInspectorTests {
    @Test("tags come off the file as the Tags column reads them")
    func tags() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("tagged.txt", contents: "x")
        try FinderTagStorage.setTags(
            [FinderTag(name: "Work"), FinderTag(name: "Red", color: .red)],
            at: tree.vfsPath("tagged.txt")
        )
        let entry = try LocalBackend().stat(at: tree.vfsPath("tagged.txt"))
        #expect(LocalSearchInspector().tagNames(of: entry) == ["Work", "Red"])
    }

    /// A dataless file's bytes are in the cloud, and reading one is what downloads it. Built from a
    /// real file holding the text, so the only thing keeping it from matching is the flag.
    @Test("a file whose bytes are not on this disk is never read")
    func datalessIsNotRead() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("cloud.txt", contents: "the needle")
        let local = try LocalBackend().stat(at: tree.vfsPath("cloud.txt"))
        let inspector = LocalSearchInspector()
        #expect(inspector.text(of: local, contains: "needle", isCancelled: { false }))

        let dataless = FileEntry(
            path: local.path,
            name: local.name,
            kind: local.kind,
            byteSize: local.byteSize,
            modificationDate: local.modificationDate,
            creationDate: local.creationDate,
            isHidden: false,
            permissions: local.permissions,
            inode: local.inode,
            isDataless: true
        )
        #expect(!inspector.text(of: dataless, contains: "needle", isCancelled: { false }))
    }

    /// The whole slice in one walk: the same `LocalBackend` listing a pane uses, the predicate a
    /// local walk compiles, and a tree with something for each clause and something to skip.
    @Test("a walk on this Mac finds by name, tag and text")
    func walk() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("docs/deep")
        try tree.writeFile("docs/plan.md", contents: "Quarterly PLAN for the café")
        try tree.writeFile("docs/deep/minutes.txt", contents: "Протокол: квартальный отчёт")
        try tree.writeFile("docs/deep/plain.txt", contents: "nothing here")
        var binary = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0x0D])
        binary.append(Data("квартальный".utf8))
        try binary.write(to: URL(fileURLWithPath: tree.path("docs/deep/image.png")))
        try FinderTagStorage.setTags(
            [FinderTag(name: "Work")],
            at: tree.vfsPath("docs/deep/plain.txt")
        )
        try FinderTagStorage.setTags([FinderTag(name: "Work")], at: tree.vfsPath("docs/deep"))

        func find(_ query: FileQuery) throws -> Set<String> {
            let results = try SubtreeSearch.find(
                under: tree.vfsPath("docs"),
                using: LocalBackend(),
                matching: SearchPredicate.walking(query, in: .local)
            )
            #expect(results.completion == .complete)
            return Set(results.hits.map(\.name))
        }

        #expect(try find(FileQuery(contentContains: "КВАРТАЛЬНЫЙ")) == ["minutes.txt"])
        #expect(try find(FileQuery(contentContains: "cafe")) == ["plan.md"])
        #expect(try find(FileQuery(tags: ["work"])) == ["plain.txt", "deep"])
        #expect(try find(FileQuery(nameContains: "plain", tags: ["Work"])) == ["plain.txt"])
        #expect(try find(FileQuery(contentContains: "nothing", tags: ["Work"])) == ["plain.txt"])
        #expect(try find(FileQuery(contentContains: "absent")).isEmpty)
    }
}
