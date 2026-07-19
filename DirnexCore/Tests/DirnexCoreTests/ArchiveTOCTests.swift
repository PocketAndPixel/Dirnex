import Foundation
import Testing

@testable import DirnexCore

@Suite("ArchiveTOC")
struct ArchiveTOCTests {
    /// Real `bsdtar -tvf` output for a zip (captured from `/usr/bin/bsdtar`), so the parser
    /// is tested against the exact column layout it will meet in production.
    private let zipListing = """
    -rw-r--r--  0 501    20         11 Jul 10 16:19 alpha.txt
    drwxr-xr-x  0 501    20          0 Jul 10 16:19 folder/
    -rw-r--r--  0 501    20         17 Jul 10 16:19 folder/beta.txt
    drwxr-xr-x  0 501    20          0 Jul 10 16:19 folder/nested/
    -rw-r--r--  0 501    20          4 Jul 10 16:19 folder/nested/deep.txt
    lrwxr-xr-x  0 501    20          0 Jul 10 16:19 link.txt -> alpha.txt
    -rw-r--r--  0 501    20         16 Jul 10 16:19 a file with spaces.txt
    """

    /// The same tree as a tar: every path is prefixed with `./` and a `./` root line leads.
    private let tarListing = """
    drwxr-xr-x  0 oleg   staff       0 Jul 10 16:19 ./
    -rw-r--r--  0 oleg   staff      11 Jul 10 16:19 ./alpha.txt
    drwxr-xr-x  0 oleg   staff       0 Jul 10 16:19 ./folder/
    lrwxr-xr-x  0 oleg   staff       0 Jul 10 16:19 ./link.txt -> alpha.txt
    -rw-r--r--  0 oleg   staff      16 Jul 10 16:19 ./a file with spaces.txt
    -rw-r--r--  0 oleg   staff      17 Jul 10 16:19 ./folder/beta.txt
    drwxr-xr-x  0 oleg   staff       0 Jul 10 16:19 ./folder/nested/
    -rw-r--r--  0 oleg   staff       4 Jul 10 16:19 ./folder/nested/deep.txt
    """

    private func names(_ entries: [ArchiveTOC.Entry]) -> Set<String> {
        Set(entries.map(\.name))
    }

    private func entry(_ entries: [ArchiveTOC.Entry], _ name: String) -> ArchiveTOC.Entry? {
        entries.first { $0.name == name }
    }

    @Test("top-level entries parse with kind and size")
    func topLevel() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        let root = toc.children(inDirectory: "/")
        #expect(names(root) == ["alpha.txt", "folder", "link.txt", "a file with spaces.txt"])

        let alpha = entry(root, "alpha.txt")
        #expect(alpha?.kind == .file)
        #expect(alpha?.byteSize == 11)
        #expect(entry(root, "folder")?.kind == .directory)
    }

    @Test("a name with spaces is preserved verbatim")
    func nameWithSpaces() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        let spaced = entry(toc.children(inDirectory: "/"), "a file with spaces.txt")
        #expect(spaced != nil)
        #expect(spaced?.byteSize == 16)
    }

    @Test("subdirectories are walkable")
    func subdirectories() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        let folder = toc.children(inDirectory: "/folder")
        #expect(names(folder) == ["beta.txt", "nested"])
        #expect(entry(folder, "beta.txt")?.byteSize == 17)

        let nested = toc.children(inDirectory: "/folder/nested")
        #expect(names(nested) == ["deep.txt"])
        #expect(entry(nested, "deep.txt")?.byteSize == 4)
    }

    @Test("a symlink carries its target text")
    func symlink() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        let link = entry(toc.children(inDirectory: "/"), "link.txt")
        #expect(link?.kind == .symlink)
        #expect(link?.symlinkDestination == "alpha.txt")
    }

    @Test("isDirectory distinguishes folders, files, and the always-present root")
    func directoryPredicate() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        #expect(toc.isDirectory(atInnerPath: "/"))
        #expect(toc.isDirectory(atInnerPath: "/folder"))
        #expect(toc.isDirectory(atInnerPath: "/folder/nested"))
        #expect(!toc.isDirectory(atInnerPath: "/alpha.txt"))
        #expect(!toc.isDirectory(atInnerPath: "/folder/beta.txt"))
    }

    @Test("entry(atInnerPath:) resolves files and reports a synthetic root directory")
    func entryLookup() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        #expect(toc.entry(atInnerPath: "/folder/beta.txt")?.name == "beta.txt")
        #expect(toc.entry(atInnerPath: "/does/not/exist") == nil)
        let root = toc.entry(atInnerPath: "/")
        #expect(root?.kind == .directory)
    }

    @Test("dates parse to a real timestamp, not distantPast")
    func dateParsing() {
        let toc = ArchiveTOC(verboseListing: zipListing)
        let alpha = entry(toc.children(inDirectory: "/"), "alpha.txt")
        #expect(alpha?.modificationDate != .distantPast)
    }

    @Test("a recent no-year member gets the current year, not the 2000 default")
    func recentDateUsesCurrentYear() {
        let calendar = Calendar(identifier: .gregorian)
        let currentYear = calendar.component(.year, from: Date())
        // A recently-modified member prints as "MMM d HH:mm" with no year; it must resolve to
        // (about) now, never the formatter's 2000 reference.
        let toc = ArchiveTOC(verboseListing: """
        -rw-r--r--  0 501    20         11 Jul 10 16:19 recent.txt
        """)
        let date = try? #require(
            entry(toc.children(inDirectory: "/"), "recent.txt")?.modificationDate
        )
        if let date {
            let year = calendar.component(.year, from: date)
            #expect(year != 2000)
            #expect(abs(year - currentYear) <= 1) // current year, or last year via boundary rollback
        }
    }

    @Test("tar's ./ prefix is stripped and the ./ root line adds no phantom entry")
    func tarPrefixStripped() {
        let toc = ArchiveTOC(verboseListing: tarListing)
        let root = toc.children(inDirectory: "/")
        #expect(names(root) == ["alpha.txt", "folder", "link.txt", "a file with spaces.txt"])
        #expect(names(toc.children(inDirectory: "/folder")) == ["beta.txt", "nested"])
    }

    @Test("intermediate directories not listed explicitly are synthesized")
    func synthesizedDirectories() {
        let toc = ArchiveTOC(verboseListing: """
        -rw-r--r--  0 501    20         42 Jul 10 16:19 docs/api/readme.md
        """)
        #expect(names(toc.children(inDirectory: "/")) == ["docs"])
        #expect(toc.isDirectory(atInnerPath: "/docs"))
        #expect(names(toc.children(inDirectory: "/docs")) == ["api"])
        #expect(toc.isDirectory(atInnerPath: "/docs/api"))
        #expect(entry(toc.children(inDirectory: "/docs/api"), "readme.md")?.byteSize == 42)
    }

    @Test("an empty listing yields an empty, rootless-but-walkable TOC")
    func emptyListing() {
        let toc = ArchiveTOC(verboseListing: "")
        #expect(toc.isEmpty)
        #expect(toc.children(inDirectory: "/").isEmpty)
        #expect(toc.isDirectory(atInnerPath: "/"))
    }

    @Test("malformed lines are skipped, not fatal")
    func malformedLines() {
        let toc = ArchiveTOC(verboseListing: """
        this is not a valid tar line
        -rw-r--r--  0 501    20         11 Jul 10 16:19 good.txt
        short line
        """)
        #expect(names(toc.children(inDirectory: "/")) == ["good.txt"])
    }
}
