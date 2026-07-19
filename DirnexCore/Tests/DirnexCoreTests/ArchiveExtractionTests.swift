import Foundation
import Testing

@testable import DirnexCore

@Suite("ArchiveExtraction")
struct ArchiveExtractionTests {
    @Test("builds the bsdtar extract argv with -x -f -C and members")
    func extractionArguments() {
        let argv = ArchiveExtraction.extractionArguments(
            archiveOnDiskPath: "/Users/me/pkg.zip",
            innerPaths: ["/docs/api/reference.md", "/a file with spaces.txt"],
            destinationDirectory: "/tmp/DirnexExtract/abc"
        )
        #expect(argv == [
            "-x", "-f", "/Users/me/pkg.zip", "-C", "/tmp/DirnexExtract/abc",
            "docs/api/reference.md", "a file with spaces.txt"
        ])
    }

    @Test("no members yields a bare extract command")
    func noMembers() {
        let argv = ArchiveExtraction.extractionArguments(
            archiveOnDiskPath: "/p/a.tar",
            innerPaths: [],
            destinationDirectory: "/tmp/x"
        )
        #expect(argv == ["-x", "-f", "/p/a.tar", "-C", "/tmp/x"])
    }

    @Test("a member drops the inner path's leading slash")
    func memberDropsLeadingSlash() {
        #expect(ArchiveExtraction.member(forInnerPath: "/docs/readme.md") == "docs/readme.md")
        // A root-level entry is a bare name, and a stray leading slash never survives.
        #expect(ArchiveExtraction.member(forInnerPath: "/alpha.txt") == "alpha.txt")
    }

    @Test("glob metacharacters in a member are backslash-escaped")
    func globEscaping() {
        // bsdtar reads members as glob patterns; these must match literally instead. Escaping
        // the opening `[` alone is enough — it defuses the character class, so the `]` is then a
        // literal (confirmed against bsdtar 3.5.3).
        #expect(ArchiveExtraction.globEscaped("weird[1].txt") == "weird\\[1].txt")
        #expect(ArchiveExtraction.globEscaped("*.txt") == "\\*.txt")
        #expect(ArchiveExtraction.globEscaped("a?b") == "a\\?b")
        #expect(ArchiveExtraction.globEscaped("back\\slash") == "back\\\\slash")
        // A plain name is left untouched.
        #expect(ArchiveExtraction.globEscaped("docs/readme.md") == "docs/readme.md")
    }

    @Test("member escaping applies through the argv builder")
    func argvEscapesMembers() {
        let argv = ArchiveExtraction.extractionArguments(
            archiveOnDiskPath: "/p/pkg.zip",
            innerPaths: ["/weird[1].txt"],
            destinationDirectory: "/tmp/x"
        )
        #expect(argv.last == "weird\\[1].txt")
    }

    @Test("extractedLocation rebuilds the full inner path under the destination")
    func extractedLocation() {
        #expect(
            ArchiveExtraction.extractedLocation(
                ofInnerPath: "/docs/api/reference.md",
                inDirectory: "/tmp/DirnexExtract/abc"
            ) == "/tmp/DirnexExtract/abc/docs/api/reference.md"
        )
        // A root-level file lands directly in the destination — and the *real* name keeps its
        // glob metacharacters (only the bsdtar member pattern is escaped, never the on-disk name).
        #expect(
            ArchiveExtraction.extractedLocation(ofInnerPath: "/weird[1].txt", inDirectory: "/tmp/x")
                == "/tmp/x/weird[1].txt"
        )
    }

    @Test("extractedLocation tolerates a trailing slash on the destination")
    func extractedLocationTrailingSlash() {
        #expect(
            ArchiveExtraction.extractedLocation(ofInnerPath: "/readme.md", inDirectory: "/tmp/x/")
                == "/tmp/x/readme.md"
        )
    }
}
