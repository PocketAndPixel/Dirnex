import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a rendered page's wiki links find, beside a document on this disk and beside one that is not
/// (PLAN.md §M39 ▸ Slice 7).
@MainActor
@Suite("Quick View wiki links")
struct QuickViewWikiLinkTests {
    @Test("on this disk, a file beside the document is found as the disk spells it, a folder is not")
    func onDisk() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let document = try tree.write("index.md", contents: "")
        _ = try tree.write("note.md", contents: "")
        try FileManager.default.createDirectory(
            at: tree.root.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        _ = try tree.write("sub/Deep.md", contents: "")
        try FileManager.default.createDirectory(
            at: tree.root.appendingPathComponent("folder.md"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("alias.md"),
            withDestinationURL: tree.root.appendingPathComponent("note.md")
        )
        let locate = QuickViewMarkdownWikiLinks.onDisk(beside: document)

        #expect(locate("note.md") == "note.md")
        #expect(locate("sub/Deep.md") == "sub/Deep.md")
        #expect(locate("alias.md") == "alias.md")
        #expect(locate("missing.md") == nil)
        #expect(locate("folder.md") == nil)
        let ignoresCase = try tree.root.resourceValues(
            forKeys: [.volumeSupportsCaseSensitiveNamesKey]
        )
        .volumeSupportsCaseSensitiveNames == false
        if ignoresCase {
            #expect(locate("Note.md") == "note.md")
            #expect(locate("sub/deep.md") == "sub/Deep.md")
        }
    }

    @Test("a page on this disk links the notes beside it and leaves other brackets as text")
    func renderedOnDisk() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let document = try tree.write("index.md", contents: """
        See [[dirnex-project-goal]] and the [[Prototype]] of an object.

        Term
        : Its definition.
        """)
        _ = try tree.write("dirnex-project-goal.md", contents: "")
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(document))
        #expect(scan.html.contains(
            "<a href=\"dirnex-project-goal.md\">dirnex-project-goal</a> and the [[Prototype]]"
        ))
        #expect(scan.html.contains("<dl>\n<dt>Term</dt>\n<dd>Its definition.</dd>\n</dl>"))
    }

    @Test(
        "a document on a server is checked against the pane's listing, not the disk under its copy"
    )
    func elsewhere() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        // A local copy with a sibling the server does not have, which must not count.
        let copy = try tree.write("README.md", contents: "")
        _ = try tree.write("stray.md", contents: "")
        let preview = QuickViewPreviewView(
            backingColor: .black,
            header: .pinned,
            findOptions: QuickViewFindOptionsStore.scratch()
        )
        var asked: [VFSPath] = []
        preview.links.namesListed = { location in
            asked.append(location)
            return ["other.md"]
        }
        let location = VFSPath(backend: VFSBackendID("sftp://u@nas:22"), path: "/srv/docs/README.md")

        let remote = preview.wikiLinkFiles(for: copy, at: location)
        #expect(remote("other.md") == "other.md")
        #expect(remote("stray.md") == nil)
        #expect(asked == [location])

        let local = preview.wikiLinkFiles(for: copy, at: .local(copy.path))
        #expect(local("stray.md") == "stray.md")
        #expect(local("other.md") == nil)
        #expect(asked == [location])
    }
}
