import Foundation
import Testing

@testable import DirnexCore

@Suite("ArchivePacking")
struct ArchivePackingTests {
    @Test("builds the bsdtar pack argv with -a -c -f -C and bare names")
    func packingArguments() {
        let argv = ArchivePacking.packingArguments(
            archiveOnDiskPath: "/Users/me/out.zip",
            sourceDirectory: "/Users/me/src",
            sourceNames: ["alpha.txt", "a file with spaces.txt", "sub"]
        )
        #expect(argv == [
            "-a", "-c", "-f", "/Users/me/out.zip", "-C", "/Users/me/src",
            "alpha.txt", "a file with spaces.txt", "sub"
        ])
    }

    @Test("names are passed verbatim — create args are literal paths, not globs")
    func namesArePassedVerbatim() {
        // Unlike extraction (where members are glob patterns), bsdtar reads create-side arguments
        // as literal filesystem paths, so a name with glob metacharacters is left untouched.
        let argv = ArchivePacking.packingArguments(
            archiveOnDiskPath: "/p/out.zip",
            sourceDirectory: "/p/src",
            sourceNames: ["weird[1].txt", "*.log"]
        )
        #expect(argv.suffix(2) == ["weird[1].txt", "*.log"])
    }

    @Test("each format's suffix drives bsdtar -a inference and round-trips as browsable")
    func formatSuffixes() {
        #expect(ArchivePacking.Format.zip.suffix == ".zip")
        #expect(ArchivePacking.Format.tarGz.suffix == ".tar.gz")
        #expect(ArchivePacking.Format.tarBz2.suffix == ".tar.bz2")
        #expect(ArchivePacking.Format.sevenZip.suffix == ".7z")
        #expect(ArchivePacking.Format.tar.suffix == ".tar")
        // Anything Dirnex can pack, it can also browse back into.
        for format in ArchivePacking.Format.allCases {
            #expect(ArchiveType.isBrowsable("out\(format.suffix)"))
        }
    }

    @Test("the format popup lists Zip first")
    func zipIsFirst() {
        #expect(ArchivePacking.Format.allCases.first == .zip)
    }

    @Test("default base name strips a single source's extension")
    func defaultBaseNameSingleFile() {
        #expect(
            ArchivePacking.defaultBaseName(
                forSourceNames: ["report.pdf"],
                sourceDirectoryName: "src"
            )
                == "report"
        )
    }

    @Test("default base name keeps a single directory's name")
    func defaultBaseNameSingleDirectory() {
        #expect(
            ArchivePacking.defaultBaseName(forSourceNames: ["docs"], sourceDirectoryName: "src")
                == "docs"
        )
    }

    @Test("default base name uses the source directory for multiple items")
    func defaultBaseNameMultiple() {
        #expect(
            ArchivePacking.defaultBaseName(
                forSourceNames: ["a.txt", "b.txt"],
                sourceDirectoryName: "myapp"
            ) == "myapp"
        )
    }

    @Test("default base name falls back to Archive at a volume root")
    func defaultBaseNameFallback() {
        #expect(
            ArchivePacking.defaultBaseName(
                forSourceNames: ["a.txt", "b.txt"],
                sourceDirectoryName: "/"
            )
                == "Archive"
        )
        #expect(
            ArchivePacking.defaultBaseName(
                forSourceNames: ["a.txt", "b.txt"],
                sourceDirectoryName: ""
            )
                == "Archive"
        )
    }

    @Test("archive filename appends the format suffix")
    func archiveFileNameAppends() {
        #expect(ArchivePacking.archiveFileName(baseName: "docs", format: .zip) == "docs.zip")
        #expect(ArchivePacking.archiveFileName(baseName: "docs", format: .tarGz) == "docs.tar.gz")
    }

    @Test("archive filename doesn't double an already-present suffix")
    func archiveFileNameNoDoubleSuffix() {
        #expect(ArchivePacking.archiveFileName(baseName: "docs.zip", format: .zip) == "docs.zip")
        // Case-insensitive, matching bsdtar's suffix inference.
        #expect(ArchivePacking.archiveFileName(baseName: "docs.ZIP", format: .zip) == "docs.ZIP")
    }

    @Test("archive filename falls back to Archive for a blank base")
    func archiveFileNameBlankBase() {
        #expect(ArchivePacking.archiveFileName(baseName: "   ", format: .zip) == "Archive.zip")
    }
}
