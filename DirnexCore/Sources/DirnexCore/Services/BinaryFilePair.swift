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

    /// Open both files for reading.
    /// - Throws: `VFSError` when either cannot be opened, and then neither is left open.
    public init(left leftPath: VFSPath, right rightPath: VFSPath) throws {
        let left = open(leftPath.path, O_RDONLY | O_CLOEXEC)
        guard left >= 0 else { throw VFSError.fromErrno(errno, path: leftPath) }
        let right = open(rightPath.path, O_RDONLY | O_CLOEXEC)
        guard right >= 0 else {
            let failure = errno
            close(left)
            throw VFSError.fromErrno(failure, path: rightPath)
        }
        self.left = left
        self.right = right
        self.leftPath = leftPath
        self.rightPath = rightPath
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
