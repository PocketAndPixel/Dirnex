import Foundation

/// The bookkeeping both checksum modes share (PLAN.md §M14 Slice 2): the running byte tally the
/// queue bar is drawn from, the one call that actually touches bytes, and the report that carries
/// the answer home.
///
/// A reference type, like `CopyRun`, so the walk and the hashing loop share one tally without
/// threading `inout` accumulators through every call. Internal rather than private because the two
/// modes are separate files — Swift `private` does not cross files (docs/NOTES.md).
final class ChecksumRunContext {
    /// Emit progress at most this often by byte volume — `CopyEngine`'s threshold, for the same
    /// reason: a main-actor hop per 128 KiB chunk would flood the caller on a big file.
    private static let emitThreshold: Int64 = 8 << 20

    let job: ChecksumJob
    let backend: any VFSBackend
    let isCancelled: @Sendable () -> Bool

    private let onProgress: @Sendable (OperationProgress) -> Void
    private var totalBytes: Int64 = 0
    private var completedBytes: Int64 = 0
    private var completedItems = 0
    private var totalItems = 0
    private var lastEmitted: Int64 = -1
    private var currentItem: VFSPath?
    private var failures: [OperationItemFailure] = []
    private var wasCancelled = false

    init(
        job: ChecksumJob,
        backend: any VFSBackend,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.job = job
        self.backend = backend
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }

    // MARK: - Hashing

    /// Hash one file, folding its bytes into the tally as they go.
    ///
    /// The dataless refusal is `ChecksumEngine`'s, not repeated here: `allowDataless` stays `false`,
    /// so an evicted iCloud or streaming-Drive placeholder throws before a single byte is read and
    /// comes back as ``ChecksumDigestOutcome/notDownloaded``. That is PLAN.md §M14's "tree sweep
    /// refuses" half — a folder is not a file anybody pointed at, so the run reports the placeholder
    /// rather than silently pulling the user's cloud drive down to answer a question about a
    /// directory.
    ///
    /// A failure still advances the tally by the file's stated size. The walk already counted those
    /// bytes into the total, so leaving them out would strand the bar short of the end on a run that
    /// genuinely finished — which reads as a hang.
    func digest(of entry: FileEntry, using algorithm: ChecksumAlgorithm) -> ChecksumDigestOutcome {
        currentItem = entry.path
        let before = completedBytes
        emitProgress(force: true)
        do {
            let digests = try ChecksumEngine.digests(
                of: entry.path,
                using: [algorithm],
                // Both closures are non-escaping and run inside this call, so they capture `self`
                // strongly: a `[weak self]` here would be nil-at-birth and silently stop reporting.
                onProgress: { read in
                    self.completedBytes = before + read
                    self.emitProgress(force: false)
                },
                isCancelled: { self.isCancelled() }
            )
            completedBytes = before + digests.byteSize
            emitProgress(force: true)
            guard let hex = digests[algorithm] else { return .unreadable }
            completedItems += 1
            return .digest(hex)
        } catch let error as ChecksumError {
            completedBytes = before + entry.byteSize
            if case .wouldDownloadPlaceholder = error { return .notDownloaded }
            return .unreadable
        } catch is CancellationError {
            wasCancelled = true
            return .unreadable
        } catch {
            completedBytes = before + entry.byteSize
            return .unreadable
        }
    }

    // MARK: - Tally

    /// Fix the run's totals from the walk, so the bar is determinate from its first update.
    func measure(files: [ChecksumWalkedFile]) {
        totalItems = files.count
        totalBytes = files.reduce(0) { $0 + $1.entry.byteSize }
        emitProgress(force: true)
    }

    /// Poll the cancel hook, latching the answer so a later `report` says so.
    func checkCancelled() -> Bool {
        if isCancelled() { wasCancelled = true }
        return wasCancelled
    }

    func recordFailure(_ path: VFSPath, _ error: any Error) {
        failures.append(
            OperationItemFailure(
                path: path,
                error: VFSError.fromErrno(errno(from: error), path: path)
            )
        )
    }

    private func emitProgress(force: Bool) {
        guard force || completedBytes - lastEmitted >= Self.emitThreshold else { return }
        lastEmitted = completedBytes
        onProgress(
            OperationProgress(
                totalBytes: totalBytes,
                completedBytes: min(completedBytes, max(totalBytes, completedBytes)),
                totalItems: totalItems,
                completedItems: completedItems,
                currentItem: currentItem
            )
        )
    }

    // MARK: - Report

    func report(outcome: ChecksumOutcome?) -> OperationReport {
        OperationReport(
            completedItems: completedItems,
            completedBytes: completedBytes,
            skipped: [],
            failures: failures,
            wasCancelled: wasCancelled,
            outcomes: [],
            checksum: outcome
        )
    }

    /// Recover the POSIX errno from a Cocoa/POSIX error so a manifest read or write failure
    /// normalizes like the rest of the VFS layer; `EIO` when nothing more specific is available.
    private func errno(from error: any Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}

// MARK: - Shared vocabulary

/// One file's hashing result, in the three shapes both modes need.
///
/// Not a `Result`: the two non-answers are ordinary outcomes a report has a row for, not errors to
/// throw. Modelling them as failures is what would let a caller `try?` them away.
enum ChecksumDigestOutcome {
    case digest(String)
    case unreadable
    case notDownloaded

    /// The report row this becomes, or `nil` when the file hashed fine.
    var status: ChecksumEntryStatus? {
        switch self {
        case .digest: return nil
        case .unreadable: return .unreadable
        case .notDownloaded: return .notDownloaded
        }
    }

    /// The verification input this becomes.
    var computation: ChecksumVerification.Computation {
        switch self {
        case let .digest(hex): return .digest(hex)
        case .unreadable: return .unreadable
        case .notDownloaded: return .notDownloaded
        }
    }
}

/// One file the walk found, with the relative name a manifest would spell it by.
struct ChecksumWalkedFile {
    let name: String
    let entry: FileEntry
}
