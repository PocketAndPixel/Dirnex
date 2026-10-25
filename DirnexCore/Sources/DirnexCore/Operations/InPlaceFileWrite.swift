import Foundation

/// Replacing a file's bytes without replacing the file (PLAN.md §M33 Slice 3).
///
/// A save from the compare window, and its undo, write this way, because it keeps the file itself.
/// The inode stays, so a second hard link still names the file and shows the new bytes, and with
/// the inode stays everything stored on it: the mode, the owner and group, Finder tags and every
/// other extended attribute, the ACL and the creation date. A symlink is written through to its
/// target, since `open(2)` follows it.
///
/// Probed 2026-10-25 on one fixture of each, with a group the folder does not have, two tags, a
/// private extended attribute, an ACL entry and a 2020 creation date. TextEdit kept the attributes
/// and wrote through the symlink, but gave the hard-linked file a new inode, leaving the other name
/// with the old bytes, and could not save a file whose ACL denies delete at all: its save stopped
/// with a temporary file left beside it. `FileManager.replaceItemAt` did the same, and replaced a
/// symlink's path with nothing unless it was resolved first. vim wrote in place and dropped both
/// tags and the private attribute. Writing in place kept everything on all five.
///
/// What it gives up is atomicity: a write that fails partway leaves the file partly written. So a
/// caller keeps the old bytes before it starts and puts them back the same way when the write fails
/// (`ComparedFileSave`, `ArchiveUndoStore.exchangeInPlace`).
enum InPlaceFileWrite {
    /// Writes `data` to the open file `descriptor` from its start, and answers 0 or an `errno`. The
    /// one seam a test replaces, to fail a write partway as a full disk would.
    typealias Writer = @Sendable (_ descriptor: Int32, _ data: Data) -> Int32

    /// Give the file at `path` the bytes `data`, then the modification time `modified` when one is
    /// given. Throws the `errno` of the step that failed; a failure while writing can leave the file
    /// partly written.
    static func replaceContents(
        ofFileAt path: String,
        with data: Data,
        modified: timespec? = nil,
        writer: Writer = writeAll
    ) throws(InPlaceWriteFailure) {
        let descriptor = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC)
        guard descriptor >= 0 else { throw .opening(errno) }
        defer { close(descriptor) }
        let written = writer(descriptor, data)
        guard written == 0 else { throw .writing(written) }
        guard fsync(descriptor) == 0 else { throw .writing(errno) }
        guard let modified else { return }
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), modified]
        guard futimens(descriptor, &times) == 0 else { throw .writing(errno) }
    }

    /// The ordinary writer: every byte, through as many `write(2)` calls as it takes.
    static let writeAll: Writer = { descriptor, data in
        data.withUnsafeBytes { buffer -> Int32 in
            guard var next = buffer.baseAddress else { return 0 }
            var left = buffer.count
            while left > 0 {
                let count = write(descriptor, next, left)
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                next += count
                left -= count
            }
            return 0
        }
    }

    /// A file's modification time, for putting it back after a write.
    static func modificationTime(ofFileAt path: String) -> timespec? {
        var status = stat()
        guard stat(path, &status) == 0 else { return nil }
        return status.st_mtimespec
    }
}

/// Why an in-place write failed, and whether the file was touched.
enum InPlaceWriteFailure: Error, Equatable {
    /// The file could not be opened for writing, so it is as it was.
    case opening(Int32)
    /// A write, the flush or setting the time failed, so the file may be partly written.
    case writing(Int32)

    var code: Int32 {
        switch self {
        case let .opening(code), let .writing(code): code
        }
    }

    /// Whether the file's bytes may have changed, so the old ones have to be put back.
    var touchedTheFile: Bool {
        if case .writing = self { return true }
        return false
    }
}
