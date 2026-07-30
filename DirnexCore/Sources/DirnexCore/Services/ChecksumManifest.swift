import Foundation

// MARK: - Format

/// The two layouts a checksum file is written in.
///
/// Dirnex *reads* every form the stock tools produce (see `ChecksumManifestParser`); this is only
/// what it writes. GNU style is the near-universal one and — since macOS 26 ships `/sbin/md5sum`,
/// `/sbin/sha1sum` and `/sbin/sha256sum` alongside `shasum` — is now produced natively here too.
public enum ChecksumManifestFormat: String, Sendable, Hashable, CaseIterable {
    /// `<hex>␣␣<name>` for text mode, `<hex>␣*<name>` for binary. What `shasum`, `md5sum` and
    /// `sha256sum` write and what `shasum -c` reads back.
    case gnu
    /// `<name>␣<hex>`, with `;` comment lines. The CRC32 world's own format.
    case sfv
}

// MARK: - Entry

/// One line of a checksum file: a name and the digest claimed for it.
public struct ChecksumManifestEntry: Sendable, Equatable {
    /// The name as the file claims it — a path relative to the directory the manifest describes,
    /// `/`-separated, so `sub/dir/file.txt` is ordinary. A leading `./` is normalized away on
    /// parse; nothing else about the name is touched, because it has to match a real file.
    ///
    /// Empty only for a bare-digest line (`crc32`'s own output is just the hex) when the caller
    /// gave no `implicitName` to attach it to.
    public let name: String
    /// The digest, lowercase hex, exactly ``ChecksumAlgorithm/hexDigitCount`` digits long.
    public let digest: String
    /// The GNU `*` marker was present. Recorded so a round-trip preserves it; it means nothing on
    /// macOS, where text and binary reads are identical.
    public let isBinary: Bool

    public init(name: String, digest: String, isBinary: Bool = false) {
        self.name = name
        self.digest = digest
        self.isBinary = isBinary
    }
}

// MARK: - Manifest

/// A parsed checksum file — one algorithm, and the names and digests it claims.
///
/// **Reading tolerantly is the point.** Apple's own tools cannot read each other: `shasum -c`
/// refuses the `openssl` and BSD `md5` forms outright ("no properly formatted SHA checksum lines
/// found"), so a user who has an `openssl dgst` output next to a download has no stock way to check
/// it. Dirnex reads all six shapes the M14 probe captured — GNU, GNU binary, BSD `md5`,
/// `openssl dgst`, `md5 -r`, and bare-hex/`.sfv` — and writes the one the receiving tool expects.
///
/// A manifest is single-algorithm by construction. A file mixing digest widths is refused with
/// ``ChecksumError/manifestMixesAlgorithms(first:second:)`` rather than half-verified, because one
/// pass over a tree can only produce one verdict.
public struct ChecksumManifest: Sendable, Equatable {
    /// The algorithm every entry uses, recovered from a `MD5 (…)` label or from the digest width —
    /// the four widths (8 · 32 · 40 · 64) are distinct, which is what makes an unlabelled line
    /// readable at all.
    public let algorithm: ChecksumAlgorithm
    /// The entries, in file order. Duplicates are kept: a file listed twice is verified twice, and
    /// silently collapsing them would hide a manifest that contradicts itself.
    public let entries: [ChecksumManifestEntry]
    /// 1-based line numbers that matched none of the known shapes and were skipped.
    ///
    /// Reported rather than swallowed. A tolerant parser that quietly drops a line turns "this file
    /// was never checked" into "this file passed", which is precisely the confusion a checksum
    /// exists to remove — so the app can say how many lines it did not understand.
    public let unrecognizedLines: [Int]

    public init(
        algorithm: ChecksumAlgorithm,
        entries: [ChecksumManifestEntry],
        unrecognizedLines: [Int] = []
    ) {
        self.algorithm = algorithm
        self.entries = entries
        self.unrecognizedLines = unrecognizedLines
    }

    // MARK: Serializing

    /// The file's text, ready to write.
    ///
    /// Defaults to ``ChecksumAlgorithm/manifestFormat`` — GNU style, or `.sfv` for CRC32. Always
    /// ends with a trailing newline, which is what every stock tool writes and what `shasum -c`
    /// expects.
    ///
    /// GNU output escapes **only a name containing a newline**, and the measurement is why. The two
    /// checkers Apple ships disagree: `shasum -c` reads both the escaped form (leading `\`, `\\` and
    /// `\n` inside) and the raw one, while `/sbin/sha256sum -c` (Darwin 1.0) rejects an escaped line
    /// outright — "WARNING: 1 line is improperly formatted" — and silently checks one file fewer.
    /// A backslash therefore goes out raw, which both accept; a newline has no raw form that any
    /// parser can split, so there the escape is the only way to say it and `shasum` is the checker
    /// that can read it back. Escaping a name that did not need it would cost compatibility for
    /// nothing.
    ///
    /// `.sfv` has no escaping convention and none is invented here: a name with a newline cannot be
    /// expressed in that format and comes out raw.
    public func serialized(format: ChecksumManifestFormat? = nil) -> String {
        let format = format ?? algorithm.manifestFormat
        return entries.map { line(for: $0, format: format) }.joined()
    }

    private func line(for entry: ChecksumManifestEntry, format: ChecksumManifestFormat) -> String {
        switch format {
        case .gnu:
            // A newline is the only character with no raw form. Backslashes ride along escaped
            // once the line is marked, because the reader unescapes the whole name.
            let needsEscape = entry.name.contains(where: { $0 == "\n" || $0 == "\r" })
            let name = needsEscape ? Self.escaped(entry.name) : entry.name
            let separator = entry.isBinary ? " *" : "  "
            return "\(needsEscape ? "\\" : "")\(entry.digest)\(separator)\(name)\n"
        case .sfv:
            return "\(entry.name) \(entry.digest)\n"
        }
    }

    private static func escaped(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: File names

    /// The file name a manifest for `base` is saved under — `Downloads.sha256`, `parts.sfv`.
    /// The extension is appended, never substituted: a manifest for `disk.iso` is `disk.iso.sha256`,
    /// so the name it describes stays readable at a glance.
    public static func suggestedFileName(
        for base: String,
        algorithm: ChecksumAlgorithm
    ) -> String {
        "\(base).\(algorithm.fileExtension)"
    }

    /// The name a bare-digest manifest is about, inferred from its own file name — `disk.iso.crc`
    /// describes `disk.iso`.
    ///
    /// This is what makes Total Commander's single-file `.crc` companion readable: its whole
    /// content is one hex number, so the name has to come from somewhere, and the only place it
    /// exists is the manifest's own name. Returns `nil` when the name carries no recognized
    /// checksum extension, which is the caller's signal not to guess.
    public static func impliedName(forManifestFileName fileName: String) -> String? {
        let known = Set(ChecksumAlgorithm.allCases.map(\.fileExtension) + ["crc"])
        let suffix = (fileName as NSString).pathExtension.lowercased()
        guard known.contains(suffix) else { return nil }
        let base = (fileName as NSString).deletingPathExtension
        return base.isEmpty ? nil : base
    }
}
