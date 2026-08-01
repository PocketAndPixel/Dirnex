import Foundation

// MARK: - Status

/// Where one name stands between a manifest and what is actually on disk.
public enum ChecksumEntryStatus: Sendable, Equatable {
    /// The file is there and its digest is the one the manifest claims.
    case ok
    /// The file is there and its digest is *not* the one the manifest claims — the answer the whole
    /// feature exists to give. Both digests are carried so the report can show them side by side.
    case mismatch(expected: String, actual: String)
    /// The manifest lists this name and the directory does not have it.
    case missing
    /// The file is there and could not be read — permission, or a file that vanished mid-run.
    /// **Not** a pass and not a failure: nothing was compared.
    case unreadable
    /// The file is there and its bytes are not on this disk (`SF_DATALESS`), so reading it would
    /// have made the cloud provider materialize it and block (docs/NOTES.md).
    ///
    /// Its own case rather than ``unreadable`` because it is the one non-answer the user can *act*
    /// on — the file is intact, it simply has to be fetched first — and because saying so is what
    /// keeps "does not download it without saying so" (PLAN.md §M14 exit criteria) visible in the
    /// report rather than buried in a generic failure.
    case notDownloaded
    /// The directory has this file and the manifest says nothing about it.
    ///
    /// Worth its own case rather than silence: a manifest that omits a file is a different answer
    /// from one that fails it, and "everything listed passed" over a manifest listing one of a
    /// hundred files is exactly the false comfort a checksum is supposed to prevent.
    case extra
}

// MARK: - Entry

/// One row of a checksum report — a verification's verdict on a name, and also the shape
/// ``ChecksumCreationSummary`` uses to name a file it could not hash.
public struct ChecksumVerificationEntry: Sendable, Equatable, Identifiable {
    /// The name as the manifest spells it, or — for ``ChecksumEntryStatus/extra`` — as the
    /// directory does.
    public let name: String
    public let status: ChecksumEntryStatus

    public init(name: String, status: ChecksumEntryStatus) {
        self.name = name
        self.status = status
    }

    public var id: String { name }
}

// MARK: - Report

/// The verdict on a whole manifest: every row, plus the one-line answer above them.
public struct ChecksumVerificationReport: Sendable, Equatable {
    public let algorithm: ChecksumAlgorithm
    /// Manifest rows in manifest order, then any ``ChecksumEntryStatus/extra`` rows in listing
    /// order. Stable, so a re-run diffs cleanly against the previous one.
    public let entries: [ChecksumVerificationEntry]

    public init(algorithm: ChecksumAlgorithm, entries: [ChecksumVerificationEntry]) {
        self.algorithm = algorithm
        self.entries = entries
    }

    public func count(of status: ChecksumEntryStatus) -> Int {
        entries.count { $0.status == status }
    }

    public var okCount: Int { count(of: .ok) }
    public var missingCount: Int { count(of: .missing) }
    public var unreadableCount: Int { count(of: .unreadable) }
    public var notDownloadedCount: Int { count(of: .notDownloaded) }
    public var extraCount: Int { count(of: .extra) }

    public var mismatchCount: Int {
        entries.count { if case .mismatch = $0.status { return true } else { return false } }
    }

    /// Every name the manifest listed verified. Extra files do **not** spoil it: a manifest is a
    /// claim about the files it names, and the directory being larger is not that claim failing —
    /// the app shows the count and lets the user judge.
    ///
    /// An unreadable or undownloaded file *does* spoil it: nothing was compared, so nothing may be
    /// asserted. This is the load-bearing half of the cloud gate — a run that skipped an evicted
    /// placeholder must never come back reading "verified".
    public var isVerified: Bool {
        mismatchCount == 0 && missingCount == 0 && unreadableCount == 0 && notDownloadedCount == 0
    }
}

// MARK: - Verification

/// Manifest × directory listing → per-entry verdict (PLAN.md §M14 Slice 1).
///
/// Pure by construction: it reads nothing. The caller has already done the I/O — it walked the
/// directory and ran ``ChecksumEngine`` over the files it could — and hands the results in, which
/// is what lets the interesting cases (a mismatch, a missing file, a manifest listing a
/// subdirectory path) be tested from literals with no temp tree at all. It is also what lets the
/// app run the hashing on `FileOperationQueue` with progress and cancellation and still produce the
/// report on the main thread.
public enum ChecksumVerification {
    /// What the caller managed to compute for one name.
    public enum Computation: Sendable, Equatable {
        /// The digest, lowercase or not — comparison is case-insensitive.
        case digest(String)
        /// The file was found but could not be read.
        case unreadable
        /// The file was found and deliberately not read, because its bytes are not on this disk.
        case notDownloaded
    }

    /// Judge a manifest against a directory.
    ///
    /// - Parameters:
    ///   - manifest: The parsed checksum file.
    ///   - listing: Every name the directory offers, relative to it and `/`-separated, matching how
    ///     the manifest spells them. **Exclude the checksum file itself** — a manifest cannot
    ///     mention its own name, so leaving it in reports it as `extra` on every run.
    ///   - computed: Name → what hashing produced. A name in `listing` with no entry here is
    ///     treated as unreadable rather than passed; a name absent from `listing` is `missing`
    ///     whatever this says.
    ///
    /// Digest comparison is case-insensitive (`openssl` and Windows `.sfv` tools both emit
    /// uppercase) and whitespace-trimmed.
    public static func verify(
        _ manifest: ChecksumManifest,
        listing: [String],
        computed: [String: Computation]
    ) -> ChecksumVerificationReport {
        let present = Set(listing)
        var entries: [ChecksumVerificationEntry] = []
        var claimed: Set<String> = []

        for entry in manifest.entries {
            claimed.insert(entry.name)
            entries.append(
                ChecksumVerificationEntry(
                    name: entry.name,
                    status: status(for: entry, present: present, computed: computed)
                )
            )
        }

        for name in listing where !claimed.contains(name) {
            entries.append(ChecksumVerificationEntry(name: name, status: .extra))
        }

        return ChecksumVerificationReport(algorithm: manifest.algorithm, entries: entries)
    }

    private static func status(
        for entry: ChecksumManifestEntry,
        present: Set<String>,
        computed: [String: Computation]
    ) -> ChecksumEntryStatus {
        guard present.contains(entry.name) else { return .missing }
        switch computed[entry.name] {
        case let .digest(actual):
            let expected = normalized(entry.digest)
            let found = normalized(actual)
            return expected == found ? .ok : .mismatch(expected: expected, actual: found)
        case .notDownloaded:
            return .notDownloaded
        // A name the caller never reported on is treated as unreadable rather than passed: a
        // tolerant "assume it was fine" is the one answer a checksum must never give.
        case .unreadable, nil:
            return .unreadable
        }
    }

    private static func normalized(_ digest: String) -> String {
        digest.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
