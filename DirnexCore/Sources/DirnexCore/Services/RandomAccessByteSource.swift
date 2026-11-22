import Foundation

/// A file's bytes, read from anywhere in it, for a reader that moves around in a file rather than
/// through it (PLAN.md §M42 ▸ Slice 3): a Matroska film keeps the index of its 10 GB at the end, and
/// a player reads its frames from wherever a seek lands.
///
/// Every read names its own offset, so one source can serve several readers at once.
public protocol RandomAccessByteSource: Sendable {
    /// The file's length in bytes.
    var length: UInt64 { get }

    /// Up to `count` bytes from `offset`: fewer only where the file ends, and none at or past its end.
    func read(at offset: UInt64, count: Int) throws -> Data
}

/// A local file, read with `pread(2)`, which takes its offset with each call and so keeps no position
/// a second reader could move.
///
/// Opening a cloud placeholder reads it and so downloads it, which is the caller's to decide before it
/// gets here.
public final class FileByteSource: RandomAccessByteSource {
    private let descriptor: Int32
    public let length: UInt64

    public init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.lastError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = Self.lastError()
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        length = UInt64(max(0, status.st_size))
    }

    deinit {
        close(descriptor)
    }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length, offset <= UInt64(Int64.max) else { return Data() }
        let wanted = Int(min(UInt64(count), length - offset))
        var data = Data(count: wanted)
        var filled = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while filled < wanted {
                let got = pread(
                    descriptor,
                    base + filled,
                    wanted - filled,
                    off_t(offset) + off_t(filled)
                )
                if got > 0 {
                    filled += got
                } else if got == 0 {
                    // The file shrank since it was opened.
                    break
                } else if errno != EINTR {
                    throw Self.lastError()
                }
            }
        }
        return filled == wanted ? data : data.prefix(filled)
    }

    private static func lastError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// Bytes already in memory, read as a file would be.
public struct DataByteSource: RandomAccessByteSource {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public var length: UInt64 { UInt64(data.count) }

    public func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0, offset < length else { return Data() }
        let start = data.startIndex + Int(offset)
        let end = start + min(count, data.endIndex - start)
        return data.subdata(in: start..<end)
    }
}
