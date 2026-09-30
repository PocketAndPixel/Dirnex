import Foundation
import Testing

@testable import DirnexCore

@Suite("ArchiveMutation")
struct ArchiveMutationTests {
    @Test("extract-all argv is a bare -x with no member list")
    func extractAllArguments() {
        let argv = ArchiveMutation.extractAllArguments(
            archiveOnDiskPath: "/Users/me/pkg.zip",
            into: "/tmp/DirnexArchiveWrite/abc"
        )
        #expect(argv == ["-x", "-f", "/Users/me/pkg.zip", "-C", "/tmp/DirnexArchiveWrite/abc"])
    }

    @Test("repack-all argv packs the whole working tree via '.'")
    func repackAllArguments() {
        let argv = ArchiveMutation.repackAllArguments(
            newArchiveOnDiskPath: "/Users/me/.dirnex-rewrite-TOK-pkg.zip",
            from: "/tmp/DirnexArchiveWrite/abc"
        )
        #expect(argv == [
            "-a", "-c", "-f", "/Users/me/.dirnex-rewrite-TOK-pkg.zip",
            "-C", "/tmp/DirnexArchiveWrite/abc", "."
        ])
    }

    @Test("repack forces --format zip for the zip-family aliases -a misreads")
    func repackForcesZipForAliases() {
        // .jar / .cbz are zip containers, but `bsdtar -a` treats them as tar; an explicit
        // --format zip keeps them zip on repack.
        for name in ["book.cbz", "app.JAR"] {
            let argv = ArchiveMutation.repackAllArguments(
                newArchiveOnDiskPath: "/p/.dirnex-rewrite-T-\(name)",
                from: "/tmp/w"
            )
            #expect(argv.prefix(4) == ["-a", "-c", "--format", "zip"])
        }
        // Everything -a infers correctly gets no override.
        for name in ["pkg.zip", "a.7z", "b.tar", "c.tgz", "d.tar.gz", "e.txz", "f.tar.zst"] {
            #expect(ArchiveMutation.formatOverrideArguments(forArchiveNamed: name).isEmpty)
        }
    }

    @Test("workingLocation rebuilds the exact on-disk path of an inner member")
    func workingLocation() {
        #expect(
            ArchiveMutation.workingLocation(
                ofInnerPath: "/docs/api/x.md",
                inWorkingDirectory: "/tmp/w"
            ) == "/tmp/w/docs/api/x.md"
        )
        // A root member lands directly in the working dir, and the *real* name keeps any glob
        // metacharacters — deletion is by literal path, so nothing is ever escaped here.
        #expect(
            ArchiveMutation.workingLocation(
                ofInnerPath: "/weird[1].txt",
                inWorkingDirectory: "/tmp/w"
            )
                == "/tmp/w/weird[1].txt"
        )
        // Tolerates a trailing slash on the working directory.
        #expect(
            ArchiveMutation.workingLocation(ofInnerPath: "/a.txt", inWorkingDirectory: "/tmp/w/")
                == "/tmp/w/a.txt"
        )
    }

    @Test("additionDirectory maps an inner directory into the extracted working tree")
    func additionDirectory() {
        #expect(
            ArchiveMutation.additionDirectory(
                forInnerDirectory: "/docs",
                inWorkingDirectory: "/tmp/w"
            ) == "/tmp/w/docs"
        )
        // A nested inner directory keeps its full path under the working dir.
        #expect(
            ArchiveMutation.additionDirectory(
                forInnerDirectory: "/a/b",
                inWorkingDirectory: "/tmp/w"
            ) == "/tmp/w/a/b"
        )
        // The archive root adds straight into the working directory itself — never an empty
        // trailing component.
        #expect(
            ArchiveMutation.additionDirectory(forInnerDirectory: "/", inWorkingDirectory: "/tmp/w")
                == "/tmp/w"
        )
    }

    @Test("collidingNames finds same-name members case-insensitively, preserving added order/case")
    func collidingNames() {
        let collisions = ArchiveMutation.collidingNames(
            addingNames: ["Readme.txt", "new.dat", "IMG.PNG"],
            existingNames: ["readme.txt", "img.png", "other"]
        )
        // Case-insensitive match, but the *added* spelling and order are what's reported.
        #expect(collisions == ["Readme.txt", "IMG.PNG"])
        // No overlap → nothing to replace, so a clean add needs no confirmation.
        #expect(
            ArchiveMutation.collidingNames(addingNames: ["a", "b"], existingNames: ["c"]).isEmpty
        )
    }

    // MARK: - Renaming a member in place

    @Test("a renamed member keeps its own directory")
    func renameKeepsTheDirectory() {
        #expect(
            ArchiveMutation.renamedInnerPath(ofInnerPath: "/docs/a.txt", to: "b.txt")
                == "/docs/b.txt"
        )
        // A member at the archive root keeps the leading slash, which is what `workingLocation`
        // strips again on the way to the staged tree — so root and depth take one code path.
        #expect(ArchiveMutation.renamedInnerPath(ofInnerPath: "/a.txt", to: "b.txt") == "/b.txt")
        #expect(
            ArchiveMutation.renamedInnerPath(ofInnerPath: "/a/b/c/deep.txt", to: "other.md")
                == "/a/b/c/other.md"
        )
        // A directory member renames exactly as a file does; its subtree travels with the move.
        #expect(ArchiveMutation.renamedInnerPath(ofInnerPath: "/docs", to: "guides") == "/guides")
    }

    /// The names a member cannot take, and the two that matter are the ones a *local* rename never
    /// meets: the staged tree is real filesystem paths, so `..` would climb out of the directory
    /// the member was in and land the rename somewhere nobody asked for.
    @Test("a name that would move the member instead of renaming it is refused")
    func renameRefusesNamesThatAreNotNames() {
        for bad in ["", "/", "a/b", "..", ".", "../escape.txt", "sub/deep.txt"] {
            #expect(
                ArchiveMutation.renamedInnerPath(ofInnerPath: "/docs/a.txt", to: bad) == nil,
                "\(bad) should not be a member name"
            )
        }
    }

    /// A case-only change is deliberately **allowed** through, because the staged move performs it
    /// (measured on APFS 2026-09-10) — refusing it here would make a case fix impossible inside an
    /// archive while it works everywhere else in the app.
    @Test("a case-only change is a rename like any other")
    func renameAllowsACaseOnlyChange() {
        #expect(
            ArchiveMutation.renamedInnerPath(ofInnerPath: "/docs/readme.md", to: "README.md")
                == "/docs/README.md"
        )
    }

    @Test("temporary archive name is a hidden sibling that keeps the full suffix")
    func temporaryArchiveName() {
        #expect(
            ArchiveMutation.temporaryArchiveName(forArchiveNamed: "pkg.zip", token: "TOK")
                == ".dirnex-rewrite-TOK-pkg.zip"
        )
        // The full multi-part suffix survives, so `bsdtar -a` still infers a gzip-compressed tar.
        let name = ArchiveMutation.temporaryArchiveName(
            forArchiveNamed: "backup.tar.gz",
            token: "abc"
        )
        #expect(name.hasPrefix("."))
        #expect(name.hasSuffix(".tar.gz"))
    }
}
