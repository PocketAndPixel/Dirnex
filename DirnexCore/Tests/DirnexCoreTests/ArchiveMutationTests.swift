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
