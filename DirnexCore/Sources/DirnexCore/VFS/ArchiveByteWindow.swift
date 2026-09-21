import CArchiveShim
import Foundation

/// The tail of a file, from `offset` on, presented to libarchive as though it were the whole file —
/// how the in-process reader opens the 7z archive a Windows self-extractor carries behind its stub
/// (``SelfExtractingArchive``).
///
/// libarchive reads through four callbacks and knows nothing about where they get their bytes, so
/// the window is just arithmetic: every position libarchive asks about is shifted by `offset`
/// before it reaches the file. That is exactly what a descriptor pre-seeked to the archive cannot
/// do — libarchive seeks it to absolute offsets and reads the stub (measured: `bsdtar` handed such a
/// descriptor as stdin fails with "Unexpected Property ID").
///
/// Owned by the ``ArchiveReadHandle`` it was opened on, and outlives it: the handle's `deinit` frees
/// the libarchive handle first, which calls the close callback, and only then releases this. So the
/// unretained pointer libarchive holds is valid for every call it can make.
final class ArchiveByteWindow {
    private let descriptor: Int32
    private let offset: Int64
    /// The window's own length — the file's size less `offset`. libarchive's positions run
    /// `0...length`.
    private let length: Int64
    private var position: Int64 = 0
    /// libarchive keeps a pointer into the last buffer a read returned until the next read, so the
    /// buffer is owned here rather than handed out per call.
    private let buffer: UnsafeMutableRawPointer
    private static let bufferSize = EncryptedArchiveReader.chunkSize

    /// `nil` when the file cannot be opened, or `offset` is not inside it.
    init?(path: String, offset: Int64) {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0, offset >= 0, offset <= Int64(status.st_size) else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
        self.offset = offset
        length = Int64(status.st_size) - offset
        buffer = .allocate(byteCount: Self.bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
        Darwin.close(descriptor)
    }

    /// Open `archive` over this window. Answers libarchive's status, as `archive_read_open_filename`
    /// would.
    func open(_ archive: OpaquePointer) -> Int32 {
        guard archive_read_set_seek_callback(archive, { _, context, offset, whence in
            guard let context else { return Int64(LibArchive.fatal) }
            return ArchiveByteWindow.from(context).seek(to: offset, whence: whence)
        }) == LibArchive.ok else { return LibArchive.fatal }

        return archive_read_open2(
            archive,
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            { _, context, buffer in
                guard let context, let buffer else { return -1 }
                return ArchiveByteWindow.from(context).read(into: buffer)
            },
            { _, context, request in
                guard let context else { return 0 }
                return ArchiveByteWindow.from(context).skip(request)
            },
            // The descriptor belongs to this object's lifetime, not to libarchive's.
            { _, _ in LibArchive.ok }
        )
    }

    private static func from(_ context: UnsafeMutableRawPointer) -> ArchiveByteWindow {
        Unmanaged<ArchiveByteWindow>.fromOpaque(context).takeUnretainedValue()
    }

    // MARK: - Callbacks

    /// The next chunk, 0 at the end of the window, -1 on a read error.
    private func read(into out: UnsafeMutablePointer<UnsafeRawPointer?>) -> Int {
        out.pointee = UnsafeRawPointer(buffer)
        let remaining = length - position
        guard remaining > 0 else { return 0 }
        let count = Int(min(Int64(Self.bufferSize), remaining))
        var got: Int
        repeat {
            got = pread(descriptor, buffer, count, off_t(offset + position))
        } while got < 0 && errno == EINTR
        guard got >= 0 else { return -1 }
        position += Int64(got)
        return got
    }

    /// Step forward without reading, never past the end; answers how far it went.
    private func skip(_ request: Int64) -> Int64 {
        let step = max(0, min(request, length - position))
        position += step
        return step
    }

    /// Move within the window. A position outside it is refused rather than clamped, since
    /// libarchive only asks for positions it computed from the archive's own headers — a request
    /// past the end is a damaged archive, and answering it with a different position would hand
    /// the 7z reader bytes it did not ask for.
    private func seek(to request: Int64, whence: Int32) -> Int64 {
        let target: Int64
        switch whence {
        case SEEK_SET: target = request
        case SEEK_CUR: target = position + request
        case SEEK_END: target = length + request
        default: return Int64(LibArchive.fatal)
        }
        guard target >= 0, target <= length else { return Int64(LibArchive.fatal) }
        position = target
        return target
    }
}
