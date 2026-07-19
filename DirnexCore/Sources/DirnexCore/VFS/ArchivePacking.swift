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
    }

    /// The `bsdtar` argv that packs `sourceNames` (bare names under `sourceDirectory`) into a new
    /// archive at `archiveOnDiskPath`. `-a` infers the format from the archive suffix, `-c`
    /// creates (overwriting any existing file — the app resolves that collision first), and `-C`
    /// makes the names archive-relative. Names are passed verbatim: `bsdtar` reads them as literal
    /// filesystem paths on create, so a name with glob metacharacters needs no escaping.
    public static func packingArguments(
        archiveOnDiskPath: String,
        sourceDirectory: String,
        sourceNames: [String]
    ) -> [String] {
        ["-a", "-c", "-f", archiveOnDiskPath, "-C", sourceDirectory] + sourceNames
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
