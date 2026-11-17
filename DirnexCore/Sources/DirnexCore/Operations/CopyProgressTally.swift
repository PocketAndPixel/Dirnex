import Foundation

/// What a copy has done so far, counted, and when to say so: the running tally behind every
/// ``OperationProgress`` the copy engine sends.
///
/// Split out of `CopyEngine.swift` when the file-by-file half (``TransferFiles``, PLAN.md §M41) took
/// `CopyRun` past the lint ceilings, and a concept of its own regardless: `CopyRun` decides what to
/// move and how, and this keeps the count and paces the reports. Mutated only on the copy's own
/// thread, like the `CopyRun` that owns it.
struct CopyProgressTally {
    /// Report at most this often by byte volume, so a large file reports smoothly without a
    /// main-actor hop per 1 MiB chunk…
    static let emitThreshold: Int64 = 8 << 20
    /// …or once this many seconds have passed, so a run of small files and a slow link both report.
    /// Measured 2026-11-17: the chunked path took 3 000 4 KB files in about half a second, about
    /// 6 000 a second, so a report per file would be thousands of snapshots a second.
    static let emitInterval: TimeInterval = 0.1

    /// A point to take the tally back to: a failed attempt's partial bytes and files are not kept.
    struct Mark {
        fileprivate let bytes: Int64
        fileprivate let files: Int
    }

    private let onProgress: @Sendable (OperationProgress) -> Void
    private let uptime: @Sendable () -> TimeInterval
    private let totalItems: Int

    private var totalBytes: Int64 = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var completedItems = 0
    private var totalFiles = 0
    private var completedFiles = 0
    /// The file being written now, and how far into it.
    private var currentFile: VFSPath?
    private var currentFileBytes: Int64 = 0
    private var currentFileSize: Int64 = 0
    private var lastEmitted: Int64 = -1
    private var lastEmittedAt: TimeInterval = -.infinity

    init(
        totalItems: Int,
        onProgress: @escaping @Sendable (OperationProgress) -> Void,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.totalItems = totalItems
        self.onProgress = onProgress
        self.uptime = uptime
    }

    /// The pre-scan's totals, and the first report.
    mutating func begin(totalBytes: Int64, totalFiles: Int) {
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        emit(current: nil, force: true)
    }

    var mark: Mark { Mark(bytes: completedBytes, files: completedFiles) }

    /// Take back what a failed attempt had tallied since `mark`.
    mutating func rollBack(to mark: Mark) {
        completedBytes = mark.bytes
        completedFiles = mark.files
        currentFile = nil
    }

    /// Something landed whole, with no file to follow: a clone or rename of a source, or a link.
    mutating func add(bytes: Int64, files: Int) {
        completedBytes += bytes
        completedFiles += files
    }

    /// The engine starts writing `entry`: name it, when the clock allows.
    mutating func startFile(_ entry: FileEntry) {
        currentFile = entry.path
        currentFileBytes = 0
        currentFileSize = entry.byteSize
        emit(current: entry.path, force: false)
    }

    /// `delta` more bytes of the file being written.
    mutating func wrote(_ delta: Int64, of path: VFSPath) {
        completedBytes += delta
        currentFileBytes += delta
        emit(current: path, force: false)
    }

    /// The file being written is done. It stays named until the next one starts, or the source ends.
    mutating func finishFile() {
        completedFiles += 1
    }

    /// One top-level source is done: add what was not already tallied on the way, clear the file
    /// being written, since none is, and report.
    mutating func finishItem(bytes: Int64, files: Int) {
        add(bytes: bytes, files: files)
        completedItems += 1
        currentFile = nil
        emit(current: nil, force: true)
    }

    mutating func emit(current: VFSPath?, force: Bool) {
        let now = uptime()
        guard force
            || completedBytes - lastEmitted >= Self.emitThreshold
            || now - lastEmittedAt >= Self.emitInterval
        else { return }
        lastEmitted = completedBytes
        lastEmittedAt = now
        onProgress(OperationProgress(
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            totalItems: totalItems,
            completedItems: completedItems,
            currentItem: current,
            files: TransferFiles(
                total: totalFiles,
                completed: completedFiles,
                current: currentFile,
                currentCompletedBytes: currentFile == nil ? 0 : currentFileBytes,
                currentTotalBytes: currentFile == nil ? 0 : currentFileSize
            )
        ))
    }
}
