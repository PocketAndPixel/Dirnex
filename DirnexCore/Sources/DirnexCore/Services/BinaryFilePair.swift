import Foundation

/// Two local files held open, read at the same offsets (PLAN.md §M37 Slice 1).
///
/// A file of any size opens without reading it: the view asks for the pages on screen. Reads are
/// `pread`s, which share no file position, so any number can run at once on any thread. Each call
/// blocks, and a file on a slow mount blocks for as long as that takes, so call it off the main
/// thread.
///
/// Held open rather than opened per read so a file saved over by rename goes on being the file
/// that was compared, rather than the rows above the fold being one version and the rows below
/// another.
public final class BinaryFilePair: Sendable {
    private let left: Int32
    private let right: Int32
    private let leftPath: VFSPath
    private let rightPath: VFSPath
    /// What `fstat` said about each file when it was opened, so a window's rows and the scan behind
    /// them agree on the sizes even if a file changes a moment later.
    let leftSubject: ComparisonSubject
    let rightSubject: ComparisonSubject

    /// Open both files for reading. Opening reads no bytes, so an evicted cloud file is not
    /// downloaded by this.
    /// - Throws: `VFSError` when either cannot be opened, and then neither is left open.
    public init(left leftPath: VFSPath, right rightPath: VFSPath) throws {
        let left = try Self.open(leftPath)
        do {
            let right = try Self.open(rightPath)
            self.left = left.descriptor
            self.right = right.descriptor
            leftSubject = left.subject
            rightSubject = right.subject
        } catch {
            close(left.descriptor)
            throw error
        }
        self.leftPath = leftPath
        self.rightPath = rightPath
    }

    /// `O_NONBLOCK` so a named pipe answers at once and is refused as not a regular file, where a
    /// plain open would wait for a writer that may never come.
    private static func open(_ path: VFSPath) throws -> (
        descriptor: Int32,
        subject: ComparisonSubject
    ) {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw VFSError.fromErrno(errno, path: path) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let failure = errno
            close(descriptor)
            throw VFSError.fromErrno(failure, path: path)
        }
        return (descriptor, ComparisonSubject(
            path: path,
            isRegularFile: (status.st_mode & S_IFMT) == S_IFREG,
            byteSize: Int64(status.st_size),
            isDataless: (status.st_flags & UInt32(SF_DATALESS)) != 0
        ))
    }

    /// The left file's size when it was opened.
    public var leftByteSize: Int64 {
        leftSubject.byteSize
    }

    /// The right file's size when it was opened.
    public var rightByteSize: Int64 {
        rightSubject.byteSize
    }

    deinit {
        close(left)
        close(right)
    }

    /// One page of both files. Short or empty past either file's end, which is how a row learns a
    /// side has no byte there.
    public func page(_ index: Int64) throws -> BinaryPage {
        let offset = index * Int64(BinaryPage.byteCount)
        return try BinaryPage(
            index: index,
            left: read(left, path: leftPath, at: offset),
            right: read(right, path: rightPath, at: offset)
        )
    }

    private func read(_ descriptor: Int32, path: VFSPath, at offset: Int64) throws -> [UInt8] {
        try [UInt8](unsafeUninitializedCapacity: BinaryPage.byteCount) { buffer, count in
            count = try Self.fill(
                UnsafeMutableRawBufferPointer(buffer),
                from: descriptor,
                at: offset,
                path: path
            )
        }
    }

    /// Fill both buffers from `offset`, up to `count` bytes each, and answer how many bytes both now
    /// hold. Less than `count` only where a file ended.
    func read(
        _ count: Int,
        at offset: Int64,
        into leftBuffer: UnsafeMutableRawBufferPointer,
        _ rightBuffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        let leftCount = try Self.fill(
            UnsafeMutableRawBufferPointer(rebasing: leftBuffer[..<count]),
            from: left,
            at: offset,
            path: leftPath
        )
        let rightCount = try Self.fill(
            UnsafeMutableRawBufferPointer(rebasing: rightBuffer[..<count]),
            from: right,
            at: offset,
            path: rightPath
        )
        return min(leftCount, rightCount)
    }

    /// Read until `buffer` is full or the file ends. One `pread` can come back short on a network
    /// mount with more still to give, and treating that as the end of the file would misalign the
    /// two sides.
    private static func fill(
        _ buffer: UnsafeMutableRawBufferPointer,
        from descriptor: Int32,
        at offset: Int64,
        path: VFSPath
    ) throws -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        var filled = 0
        while filled < buffer.count {
            let count = pread(
                descriptor,
                base + filled,
                buffer.count - filled,
                offset + Int64(filled)
            )
            if count > 0 {
                filled += count
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw VFSError.fromErrno(errno, path: path)
            }
        }
        return filled
    }
}
