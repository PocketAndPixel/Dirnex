// MARK: - Job

/// What a queued checksum operation is being asked to do (PLAN.md §M14 Slice 2).
///
/// Carried as the payload of `FileOperation.Kind.checksum`, which is the first time that enum has
/// described anything other than moving bytes from A to B. The two modes share a queue, a progress
/// bar and a cancel button, and nothing else: one writes a file, the other reads one.
///
/// Note which side the algorithm sits on. **Creating** needs it chosen — SHA-256 unless the user
/// picked an interop format. **Verifying** must never be told it: the manifest names its own
/// algorithm (by a `MD5 (…)` label, or by the digest width, which is distinct for all four), and a
/// caller that could override it could quietly verify a SHA-256 file as MD5 and report every line
/// as a mismatch.
public enum ChecksumJob: Sendable, Equatable {
    /// Hash the operation's sources — descending into any directory among them — and write the
    /// result to `manifest`.
    ///
    /// `manifest` must sit in the directory the names are relative to, which is the operation's
    /// `destinationDirectory`. That is not a convention this code invented: every checksum format
    /// spells its names relative to the file's own location, so a manifest written anywhere else
    /// describes files that are not there.
    case create(manifest: VFSPath, algorithm: ChecksumAlgorithm)

    /// Read the manifest at `manifest` and check what it names against the directory it sits in.
    case verify(manifest: VFSPath)

    /// The checksum file being written or read.
    public var manifest: VFSPath {
        switch self {
        case let .create(manifest, _), let .verify(manifest): return manifest
        }
    }

    /// The directory the manifest's names are relative to — its own parent, always.
    ///
    /// Falls back to the manifest path itself only at a backend root, where a file cannot live
    /// anyway; the runner's own `stat` refuses that case rather than this accessor guessing.
    public var root: VFSPath { manifest.parent ?? manifest }
}

// MARK: - Outcome

/// What a finished checksum job produced, carried home on `OperationReport/checksum`.
///
/// A third case for failure, rather than folding into `OperationReport.failures`: those are
/// `VFSError`s about a *path*, and the two ways a checksum job fails before it ever reaches a file
/// — an unreadable manifest, a manifest mixing algorithms — are ``ChecksumError``s about the job.
public enum ChecksumOutcome: Sendable, Equatable {
    case created(ChecksumCreationSummary)
    case verified(ChecksumVerificationReport)
    /// The job could not start: the manifest could not be read or parsed.
    case failed(ChecksumError)
}

// MARK: - Creation summary

/// What a `.create` job wrote, and what it could not.
///
/// There is no per-file table here on purpose — a list of a hundred digests nobody reads is not a
/// result, the file is. What the user needs is the count, the file's name, and the one thing that
/// would otherwise pass silently: the files that were **skipped**, each named with why.
public struct ChecksumCreationSummary: Sendable, Equatable {
    /// The checksum file that was written.
    public let manifest: VFSPath
    public let algorithm: ChecksumAlgorithm
    /// How many names the manifest ended up claiming.
    public let writtenCount: Int
    /// Files found but not hashed, in walk order — each carrying
    /// ``ChecksumEntryStatus/unreadable`` or ``ChecksumEntryStatus/notDownloaded``.
    ///
    /// A manifest that quietly omits a file is the same false comfort
    /// ``ChecksumEntryStatus/extra`` exists to prevent, one step earlier: it would verify perfectly
    /// ever after while saying nothing about the file it never looked at.
    public let skipped: [ChecksumVerificationEntry]

    public init(
        manifest: VFSPath,
        algorithm: ChecksumAlgorithm,
        writtenCount: Int,
        skipped: [ChecksumVerificationEntry]
    ) {
        self.manifest = manifest
        self.algorithm = algorithm
        self.writtenCount = writtenCount
        self.skipped = skipped
    }

    /// Everything the walk found was hashed and written.
    public var isComplete: Bool { skipped.isEmpty }
}
