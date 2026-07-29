import Foundation

/// Builds the `bsdtar` command that packs files into a new archive — the pure, tested half of
/// TC's Pack (Alt+F5, PLAN.md §M4 "pack via F5-with-archive-target"), the inverse of
/// `ArchiveExtraction`. The app's `ArchivePacker` runs the process; this touches no disk and
/// spawns nothing, so it stays unit-testable.
///
/// Packing is *not* a cross-backend copy through `CopyEngine`; it produces a single archive file
/// directly. `bsdtar -a -c -f <archive> -C <sourceDir> <name>…` creates the archive with the
/// format inferred from the archive's own suffix (`-a`) and stores each source under its bare
/// name relative to `<sourceDir>` (`-C`), so the archive holds `docs/…`, not the source's
/// absolute path. Every selected item shares one parent — the pane's current directory — so a
/// single `-C` covers them all. Unlike extraction, the create-side arguments are literal file
/// paths, not glob patterns (validated against bsdtar 3.5.3 / libarchive 3.7.4), so no member
/// escaping is needed.
public enum ArchivePacking {
    /// A container format Dirnex can create. The raw suffix drives `bsdtar -a`'s format inference,
    /// and `browsableSuffixes` guarantees every one of these round-trips back into a browsable
    /// archive. `allCases` is the order the pack dialog lists them, so `.zip` (the common default)
    /// comes first.
    public enum Format: String, CaseIterable, Sendable, Hashable {
        case zip
        case tarGz
        case tarBz2
        case sevenZip
        case tar

        /// The filename suffix `bsdtar -a` maps to this format (and that `ArchiveType.isBrowsable`
        /// recognizes, so a freshly packed archive is immediately browsable).
        public var suffix: String {
            switch self {
            case .zip: return ".zip"
            case .tarGz: return ".tar.gz"
            case .tarBz2: return ".tar.bz2"
            case .sevenZip: return ".7z"
            case .tar: return ".tar"
            }
        }

        /// The label the pack dialog's format popup shows.
        public var displayName: String {
            switch self {
            case .zip: return "Zip"
            case .tarGz: return "Tarball (gzip)"
            case .tarBz2: return "Tarball (bzip2)"
            case .sevenZip: return "7-Zip"
            case .tar: return "Tar (uncompressed)"
            }
        }

        /// Whether this format's writer accepts `--options compression-level=N`. Plain `.tar`
        /// compresses nothing, and handing it the option is not ignored — `bsdtar` exits 1 with
        /// "Undefined option: `compression-level'" and writes no archive (measured, libarchive
        /// 3.7.4), so the flag has to be withheld rather than passed and hoped over.
        public var supportsCompressionLevel: Bool {
            switch self {
            case .zip, .tarGz, .tarBz2, .sevenZip: return true
            case .tar: return false
            }
        }
    }

    /// How hard `bsdtar` should work, as the pack dialog offers it: three named steps rather than
    /// libarchive's 0–9, because the dial has far less range than the numbers suggest. Measured on
    /// a 2.1 MB text file (libarchive 3.7.4): zip and 7z are *byte-identical* at 6 and 9, gzip
    /// differs by 10 bytes, and only bzip2 gains anything real (367 581 → 362 527, 1.4 %). The
    /// useful end is the fast one.
    ///
    /// Level 0 is deliberately not offered. It is a true "store" only for zip and gzip — bzip2
    /// clamps it to 1 and the 7z writer still compresses — so a "Store" item would mean three
    /// different things across five formats. Users who want a stored container pick Tar.
    public enum CompressionLevel: String, CaseIterable, Sendable, Hashable {
        case fast
        case normal
        case maximum

        /// The `compression-level` value to pass, or `nil` to pass nothing at all. `.normal` is
        /// the absent option rather than an explicit `6`: libarchive's per-format default is what
        /// "normal" means, and the defaults are not all 6 (the 7z writer's is its own).
        var optionValue: Int? {
            switch self {
            case .fast: return 1
            case .normal: return nil
            case .maximum: return 9
            }
        }

        /// The label the pack dialog's compression popup shows.
        public var displayName: String {
            switch self {
            case .fast: return "Fast"
            case .normal: return "Normal"
            case .maximum: return "Maximum"
            }
        }
    }

    /// The `bsdtar` argv that packs `sourceNames` (bare names under `sourceDirectory`) into a new
    /// archive at `archiveOnDiskPath`. `-a` infers the format from the archive suffix, `-c`
    /// creates (overwriting any existing file — the app resolves that collision first), and `-C`
    /// makes the names archive-relative. Names are passed verbatim: `bsdtar` reads them as literal
    /// filesystem paths on create, so a name with glob metacharacters needs no escaping.
    ///
    /// `format` is passed alongside the path it already determines because the *level* is only
    /// legal for some formats, and getting that wrong fails the whole pack rather than degrading
    /// (see ``Format/supportsCompressionLevel``). The option is written **unprefixed**: a module
    /// prefix has to name the actual writer (`zip:`, `gzip:`, `bzip2:`, `7zip:`), so a single
    /// prefixed string breaks the moment the format changes — `bsdtar: Unknown module name: zip`.
    /// Unprefixed, libarchive offers it to whichever module is running.
    public static func packingArguments(
        archiveOnDiskPath: String,
        sourceDirectory: String,
        sourceNames: [String],
        format: Format,
        level: CompressionLevel
    ) -> [String] {
        var argv = ["-a", "-c", "-f", archiveOnDiskPath]
        if format.supportsCompressionLevel, let value = level.optionValue {
            argv += ["--options", "compression-level=\(value)"]
        }
        return argv + ["-C", sourceDirectory] + sourceNames
    }

    /// The archive base name the pack dialog pre-fills: a single source's name minus its extension
    /// (`report.pdf` → `report`, the folder `docs` → `docs`), otherwise the source directory's own
    /// name (packing a whole folder's worth of items → `<folder>`). Falls back to `Archive` when
    /// there's nothing usable (an empty directory name, e.g. a volume root).
    public static func defaultBaseName(
        forSourceNames sourceNames: [String],
        sourceDirectoryName: String
    ) -> String {
        if sourceNames.count == 1 {
            let stripped = (sourceNames[0] as NSString).deletingPathExtension
            if !stripped.isEmpty { return stripped }
        }
        let directory = sourceDirectoryName.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return directory.isEmpty ? "Archive" : directory
    }

    /// The full archive filename for a user-entered `baseName` and chosen `format`: the base name
    /// plus the format's suffix, unless the base already carries it (so typing `docs.zip` with the
    /// Zip format yields `docs.zip`, not `docs.zip.zip`). A blank base falls back to `Archive`.
    public static func archiveFileName(baseName: String, format: Format) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Archive" : trimmed
        if base.lowercased().hasSuffix(format.suffix) { return base }
        return base + format.suffix
    }
}
