import Foundation

/// What a content comparison found — the answer `prescan` gives before two files are handed to an
/// external diff tool, so the caller can skip a pointless launch or warn before an expensive one.
public enum ContentComparison: Sendable, Equatable {
    /// The two files hold identical bytes. There is nothing for a diff tool to show.
    case identical
    /// The bytes differ somewhere.
    case different
    /// At least one side is bigger than the pre-scan budget, so **nothing was read**. Settling
    /// identical-or-not would mean reading both files end to end, and a file that large is also
    /// the kind a visual diff tool struggles with — so the caller warns instead of guessing.
    /// Carries the larger of the two sizes, for the message.
    case tooLargeToScan(largestByteSize: Int64)
}

/// One side of a comparison: the path, plus everything a single `lstat` said about it.
///
/// Three facts, one syscall. `FileManager.attributesOfItem` can answer the first two and *never*
/// the third — it does not surface `st_flags` — which is why the comparator stats for itself, the
/// same move `ChecksumEngine` makes for the same reason.
///
/// It is also the seam the placeholder rule is tested through, because `SF_DATALESS` **cannot be
/// produced in a test**: probed on macOS 26, `chflags` returns success and the kernel silently drops
/// the flag, since it belongs to the file provider rather than to the file's owner. So the decision
/// half of the comparator takes subjects and the reading half supplies real ones.
struct ComparisonSubject: Equatable {
    let path: VFSPath
    let isRegularFile: Bool
    let byteSize: Int64
    /// `SF_DATALESS`: the name, size and dates are real; the bytes are not on this disk.
    let isDataless: Bool
}

/// Byte-for-byte comparison of two on-disk files (PLAN.md §M5 "Compare by content: byte
/// compare"). This is the exact-equality primitive behind the directory-synchronizer's
/// `.content` mode and the standalone "compare files by content" command.
///
/// It touches bytes, so per §2 it lives in `DirnexCore` and is tested. The comparison is
/// chunked — it never loads a whole file into memory — and short-circuits: files of
/// different sizes are unequal without reading a byte, and reading stops at the first
/// differing chunk. The caller decides where it runs (the app drives it off the main
/// thread); pass `isCancelled` to abandon a huge comparison when the user moves on.
///
/// **An evicted cloud placeholder is refused rather than read** (`allowDataless`). Reading one byte
/// of an `SF_DATALESS` file makes iCloud or Google Drive materialize the whole thing and *blocks*
/// until it lands — measured 1.1 s for 200 KB, and unbounded on a slow link — so a comparison that
/// would do it says so instead, naming the file. The caller decides what that means: a file the
/// user pointed at is worth downloading (the app asks the provider and shows a sheet with a Stop
/// button), while a sweep over a tree stops rather than pulling someone's whole cloud drive.
public enum ByteComparator {
    /// Whether the two local files hold identical bytes.
    ///
    /// - Both paths must be on the `.local` backend; anything else throws `.unsupported`
    ///   (a network read primitive arrives with `SFTPBackend`). Comparing a path with
    ///   itself is trivially `true`.
    /// - A size mismatch returns `false` immediately — no bytes are read.
    /// - Directories can't be content-compared; a non-regular file on either side throws
    ///   `.unsupported` so the caller falls back to metadata comparison.
    /// - An evicted cloud placeholder on either side throws
    ///   `.contentComparisonWouldDownload` unless `allowDataless` says the download has
    ///   already been agreed to.
    /// - Read failures (permission, vanished mid-read) throw `VFSError.io`.
    public static func localFilesEqual(
        _ lhs: VFSPath,
        _ rhs: VFSPath,
        chunkSize: Int = 128 * 1024,
        allowDataless: Bool = false,
        isCancelled: () -> Bool = { false }
    ) throws -> Bool {
        guard lhs.backend == .local, rhs.backend == .local else {
            throw VFSError.unsupported(.contentComparisonNeedsLocalFiles)
        }
        guard lhs != rhs else { return true }
        return try equal(
            try subject(lhs),
            try subject(rhs),
            chunkSize: chunkSize,
            allowDataless: allowDataless,
            isCancelled: isCancelled
        )
    }

    /// The largest file `prescan` will read through. Past this, deciding identical-or-not costs a
    /// full read of both sides — and the visual diff tool that would open next is the real problem
    /// at that size anyway, so the caller asks rather than spending the I/O to find out.
    public static let prescanByteLimit: Int64 = 64 * 1024 * 1024

    /// Look before a diff tool leaps: are these two files worth opening side by side at all?
    ///
    /// The size check comes *first* and is deliberately independent of the answer — two 2 GB files
    /// of different sizes are known-unequal for free, but that is not a reason to hand them to
    /// FileMerge. Within the budget this is exactly `localFilesEqual`, so the same short-circuits
    /// apply (a size mismatch reads no bytes; reading stops at the first differing chunk).
    ///
    /// Throws what `localFilesEqual` throws: `.unsupported` for a non-local or non-regular path or
    /// an un-downloaded placeholder, `VFSError.io` for a read failure, `CancellationError` when
    /// `isCancelled` fires.
    public static func prescan(
        _ lhs: VFSPath,
        _ rhs: VFSPath,
        byteLimit: Int64 = prescanByteLimit,
        chunkSize: Int = 128 * 1024,
        allowDataless: Bool = false,
        isCancelled: () -> Bool = { false }
    ) throws -> ContentComparison {
        guard lhs.backend == .local, rhs.backend == .local else {
            throw VFSError.unsupported(.contentComparisonNeedsLocalFiles)
        }
        guard lhs != rhs else { return .identical }
        return try prescan(
            try subject(lhs),
            try subject(rhs),
            byteLimit: byteLimit,
            chunkSize: chunkSize,
            allowDataless: allowDataless,
            isCancelled: isCancelled
        )
    }

    // MARK: - The decision half

    // Both seams below spell out every knob rather than re-declaring the public defaults, which
    // would be a second place for one number to drift from the other.
    // swiftlint:disable function_parameter_count

    /// `prescan` over subjects already read — the seam the placeholder tests drive.
    ///
    /// The size gate answers *before* the placeholder rule on purpose, and for the same reason it
    /// outranks the size-mismatch short-circuit: `tooLargeToScan` reads nothing, so it is not a
    /// comparison that would download anything. The caller that then says "open it anyway" is
    /// handing the pair to a diff tool, and making *that* read safe is the app's job, not this one's.
    static func prescan(
        _ lhs: ComparisonSubject,
        _ rhs: ComparisonSubject,
        byteLimit: Int64,
        chunkSize: Int,
        allowDataless: Bool,
        isCancelled: () -> Bool
    ) throws -> ContentComparison {
        try requireRegularFiles(lhs, rhs)
        let largest = max(lhs.byteSize, rhs.byteSize)
        guard largest <= byteLimit else { return .tooLargeToScan(largestByteSize: largest) }

        let equal = try equal(
            lhs,
            rhs,
            chunkSize: chunkSize,
            allowDataless: allowDataless,
            isCancelled: isCancelled
        )
        return equal ? .identical : .different
    }

    /// `localFilesEqual` over subjects already read — the seam the placeholder tests drive, since
    /// `SF_DATALESS` cannot be set on a test file (see ``ComparisonSubject``).
    ///
    /// **The placeholder guard sits last, immediately before the first read**, after both free
    /// answers. A dataless file carries its *real* size, so two placeholders of different sizes are
    /// known-unequal for nothing — and refusing a question that costs no download would abort a
    /// content sync over a pair it could already classify. The guard exists to stop a *read*, so it
    /// is asked exactly where a read is about to happen.
    static func equal(
        _ lhs: ComparisonSubject,
        _ rhs: ComparisonSubject,
        chunkSize: Int,
        allowDataless: Bool,
        isCancelled: () -> Bool
    ) throws -> Bool {
        try requireRegularFiles(lhs, rhs)
        guard lhs.byteSize == rhs.byteSize else { return false }
        guard lhs.byteSize > 0 else { return true } // two empty files are equal
        try requireDownloaded(lhs, rhs, allowDataless: allowDataless)

        let lhsHandle = try openForReading(lhs.path)
        defer { try? lhsHandle.close() }
        let rhsHandle = try openForReading(rhs.path)
        defer { try? rhsHandle.close() }

        while true {
            if isCancelled() { throw CancellationError() }
            let lhsChunk = try read(lhsHandle, upTo: chunkSize, at: lhs.path)
            let rhsChunk = try read(rhsHandle, upTo: chunkSize, at: rhs.path)
            if lhsChunk != rhsChunk { return false }
            if lhsChunk.isEmpty { return true } // both reached EOF in lock-step
        }
    }

    // swiftlint:enable function_parameter_count

    private static func requireRegularFiles(_ lhs: ComparisonSubject, _ rhs: ComparisonSubject) throws {
        guard lhs.isRegularFile, rhs.isRegularFile else {
            throw VFSError.unsupported(.contentComparisonNeedsRegularFile)
        }
    }

    /// Refuse a comparison whose first read would pull a file out of the cloud, naming the side that
    /// would be downloaded. `allowDataless` is the caller saying the user has already agreed to it.
    private static func requireDownloaded(
        _ lhs: ComparisonSubject,
        _ rhs: ComparisonSubject,
        allowDataless: Bool
    ) throws {
        guard !allowDataless, let placeholder = [lhs, rhs].first(where: \.isDataless) else { return }
        throw VFSError.unsupported(
            .contentComparisonWouldDownload(name: placeholder.path.lastComponent)
        )
    }

    // MARK: - Helpers

    /// What one `lstat` says about a path.
    ///
    /// `lstat` rather than `stat`, unlike `ChecksumEngine`: `FileManager.attributesOfItem` did not
    /// traverse symlinks either, so a symlink stays a non-regular file the comparator declines and
    /// the caller falls back to metadata comparison — the behaviour `DirectorySync.fileStatus`
    /// already documents and relies on.
    static func subject(_ path: VFSPath) throws -> ComparisonSubject {
        var status = stat()
        guard lstat(path.path, &status) == 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
        return ComparisonSubject(
            path: path,
            isRegularFile: (status.st_mode & S_IFMT) == S_IFREG,
            byteSize: Int64(status.st_size),
            // Free here — the flag rides along in the `stat` the size check needed anyway, which is
            // what makes the placeholder guard cost nothing over the type check already happening.
            isDataless: (status.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    private static func openForReading(_ path: VFSPath) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: URL(fileURLWithPath: path.path))
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    private static func read(_ handle: FileHandle, upTo count: Int, at path: VFSPath) throws -> Data {
        do {
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    /// Recover the POSIX errno from a Cocoa/POSIX error so failures normalize like the rest
    /// of the VFS layer; falls back to `EIO` when nothing more specific is available.
    private static func errnoValue(from error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}
