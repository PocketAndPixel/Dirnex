import Foundation

/// What a queued **plain** pack is being asked to write — every format that is not encrypted
/// (PLAN.md §4 ▸ *Smaller than a milestone*).
///
/// **Why this is a second job rather than a field on ``PackJob``.** The two write through different
/// machinery and always will: an encrypted archive is libarchive linked into this process, because
/// `bsdtar` cannot be handed a passphrase that is not readable by any `ps` (the boundary §M19 drew),
/// while a plain one is a `bsdtar` spawn — which is what keeps every format `bsdtar` knows, where
/// the libarchive path can only write zip. Folding them together would mean one job with a
/// passphrase that must be `nil` for half its formats and a format that must be zip for the other
/// half, which is a setting with illegal values rather than a description.
///
/// What changed is only **where it runs**. Until 2026-08-30 a plain pack was a spawn on the app's
/// own thread with no job, no bar and no Stop, so a pack bound for a server reported its upload
/// through the status line while encrypting the same archive put both halves on the queue. The work
/// is identical in kind — minutes of reading, then a transfer — so the reason for the split was
/// never about the work.
public struct PlainPackJob: Sendable, Equatable {
    /// What goes in, and where each one's bytes are on this disk. Always local by the time a job
    /// exists: a row that was not here is staged first, which since 2026-08-30 includes a folder.
    public let sources: [PackSource]

    /// Where the finished archive lands, on **any** backend that accepts uploads. A local
    /// destination is written in place; a remote one is built in a temp directory and transferred,
    /// which is ``PackStaging``'s whole subject.
    public let archive: VFSPath

    /// Which container, and therefore which `bsdtar` argv. Unlike ``PackJob`` this is a real choice
    /// — it is the reason the plain path exists.
    public let format: ArchivePacking.Format

    public let level: ArchivePacking.CompressionLevel

    public init(
        sources: [PackSource],
        archive: VFSPath,
        format: ArchivePacking.Format,
        level: ArchivePacking.CompressionLevel = .normal
    ) {
        self.sources = sources
        self.archive = archive
        self.format = format
        self.level = level
    }

    /// What to hand the writer, once the runner has decided where the archive is built.
    ///
    /// The build path is the runner's to choose and not the job's: a local destination is written
    /// in place and a remote one in a temp directory, which is ``PackStaging``'s subject.
    public func request(buildingAt buildPath: String) -> PlainPackRequest {
        PlainPackRequest(
            sources: sources,
            archiveOnDiskPath: buildPath,
            format: format,
            level: level
        )
    }
}

/// One spawn's worth of instruction: what to read, where to write it, and in which container.
public struct PlainPackRequest: Sendable, Equatable {
    public let sources: [PackSource]
    /// An absolute **local** path. Where the archive finally belongs is not the writer's business.
    public let archiveOnDiskPath: String
    public let format: ArchivePacking.Format
    public let level: ArchivePacking.CompressionLevel

    public init(
        sources: [PackSource],
        archiveOnDiskPath: String,
        format: ArchivePacking.Format,
        level: ArchivePacking.CompressionLevel
    ) {
        self.sources = sources
        self.archiveOnDiskPath = archiveOnDiskPath
        self.format = format
        self.level = level
    }
}

/// Spawning `bsdtar` on behalf of a queued plain pack.
///
/// The seam PLAN.md §2 asks for: non-hermetic subprocess I/O lives in the **app**, the pure parse of
/// its output (``BsdtarProgress``) lives here, and the runner sees neither a process nor a pipe. It
/// is injected into `FileOperationQueue` the way the backend is, rather than carried on the job,
/// because a job is a *description* — one that has to stay `Equatable` so the queue can tell two
/// apart, and comparing two spawners is not a question with an answer.
///
/// **The two closures are the whole contract, and both are load-bearing.** `onProgress` is the only
/// thing `bsdtar` will tell anyone about its own work, and it arrives because the implementation
/// asks (SIGINFO — see ``BsdtarProgress``); `isCancelled` must actually reach the process, because
/// the queue's Stop is a promise this project has already had to fix once for the remote transports
/// (docs/NOTES.md ▸ curl for S3, on a Stop that let the whole transfer finish).
public protocol PlainPackWriting: Sendable {
    /// Write the request's sources into an archive at its path, blocking until it is done.
    ///
    /// - Throws `CancellationError` when `isCancelled` fired — distinct from a failure, because a
    ///   pack the user stopped is not a pack that went wrong, and the queue reports the two
    ///   differently.
    /// - Throws a `VFSError` when the tool could not run or the archive did not land. A partial
    ///   archive is the implementation's to sweep: `bsdtar` leaves one behind on SIGTERM (measured),
    ///   and a half-written archive that stays is worse than none, because it opens.
    func pack(
        _ request: PlainPackRequest,
        onProgress: @escaping @Sendable (BsdtarProgressSample) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws
}
