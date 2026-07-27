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
            sourceNames: ["alpha.txt", "a file with spaces.txt", "sub"],
            format: .zip,
            level: .normal
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
            sourceNames: ["weird[1].txt", "*.log"],
            format: .zip,
            level: .normal
        )
        #expect(argv.suffix(2) == ["weird[1].txt", "*.log"])
    }

    // MARK: - Compression level

    @Test("a non-default level becomes an unprefixed --options before -C")
    func levelBecomesOptions() {
        // Unprefixed on purpose: a module prefix has to name the running writer (`zip:`, `gzip:`,
        // `bzip2:`, `7zip:`), so one prefixed string would fail as soon as the format changed.
        for (level, value) in [(ArchivePacking.CompressionLevel.fast, "1"), (.maximum, "9")] {
            let argv = ArchivePacking.packingArguments(
                archiveOnDiskPath: "/p/out.zip",
                sourceDirectory: "/p/src",
                sourceNames: ["a.txt"],
                format: .zip,
                level: level
            )
            #expect(argv == [
                "-a", "-c", "-f", "/p/out.zip",
                "--options", "compression-level=\(value)",
                "-C", "/p/src", "a.txt"
            ])
        }
    }

    @Test("normal passes no option at all — libarchive's own per-format default")
    func normalPassesNoOption() {
        for format in ArchivePacking.Format.allCases {
            let argv = ArchivePacking.packingArguments(
                archiveOnDiskPath: "/p/out\(format.suffix)",
                sourceDirectory: "/p/src",
                sourceNames: ["a.txt"],
                format: format,
                level: .normal
            )
            #expect(!argv.contains("--options"), "\(format) got an option for .normal")
        }
    }

    @Test("tar takes no compression level — the option would fail the pack, not be ignored")
    func tarTakesNoLevel() {
        #expect(!ArchivePacking.Format.tar.supportsCompressionLevel)
        for format in ArchivePacking.Format.allCases where format != .tar {
            #expect(format.supportsCompressionLevel, "\(format) should accept a level")
        }
        for level in ArchivePacking.CompressionLevel.allCases {
            let argv = ArchivePacking.packingArguments(
                archiveOnDiskPath: "/p/out.tar",
                sourceDirectory: "/p/src",
                sourceNames: ["a.txt"],
                format: .tar,
                level: level
            )
            #expect(argv == ["-a", "-c", "-f", "/p/out.tar", "-C", "/p/src", "a.txt"])
        }
    }

    @Test("every level maps to a value bsdtar accepts, and Normal is preselected")
    func levelValuesAreInRange() {
        // Out of range is not clamped by libarchive: it exits 1 with "Undefined option", so the
        // offered values must stay inside 1…9. Level 0 is deliberately not offered — it means
        // three different things across the five formats.
        for level in ArchivePacking.CompressionLevel.allCases {
            guard let value = level.optionValue else { continue }
            #expect((1...9).contains(value), "\(level) maps to \(value)")
        }
        #expect(ArchivePacking.CompressionLevel.normal.optionValue == nil)
        #expect(ArchivePacking.CompressionLevel.allCases.contains(.normal))
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
