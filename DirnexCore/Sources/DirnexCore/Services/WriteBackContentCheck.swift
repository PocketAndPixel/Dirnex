import Foundation

/// What comparing the server's bytes with an edit's base found.
public enum WriteBackContentVerdict: Sendable, Equatable {
    /// Nothing for the bytes to add: a reading is missing, the size or time already differ, or
    /// entity tags on both sides settled it.
    case notAsked
    /// No base is kept for the copy, so there is nothing to compare the server's bytes with.
    case noBase
    /// The server's file is larger than ``RemoteFetchPurpose/writeBackCheck`` fetches unasked, so its
    /// bytes were not brought down.
    case overLimit
    /// The server holds the base's bytes: an upload over them loses nobody's edit.
    case same
    /// The server's bytes differ from the base: somebody wrote the file.
    case different
    /// The server's bytes could not be brought down or compared.
    case unreadable

    /// Whether this verdict is evidence of a write the size and time did not show.
    public var isChange: Bool { self == .different }
}

/// Settles a write-back's "unchanged" by the server's bytes, where the size and time cannot (PLAN.md
/// §M34 ▸ 2026-10-27, the content check).
///
/// SFTP and FTP give a write-back check a size and a time and no entity tag. Over SFTP that time is
/// a minute, and over FTP without `MLSD` it is a minute without a year, so a same-size write in the
/// minute of Dirnex's own upload reads as no write at all and the next save goes over it. Seen live
/// 2026-10-27, "Goodbye" changed to "See you" on the server (docs/NOTES.md ▸ sftp).
///
/// **The bytes answer the question the check is asking.** Since M34 Slice 4 each edit of a server
/// file keeps a base: the server's bytes at the revision its copy is checked against. A server still
/// holding them loses nothing to the upload, whoever touched the file, and a server holding anything
/// else has somebody's edit on it. So a match is proof, as a matching entity tag is, and a finer
/// clock would only have narrowed the window. Probed 2026-10-27 against the throwaway servers:
///
/// - `sftp`'s `ls -la` is a minute, and two rows three seconds apart were byte-identical;
/// - `get -a -p` onto an empty file of the same size gives the server's second for no bytes, and a
///   second is still a window;
/// - exec `cksum` reads the content for any size, but not on an account confined to `internal-sftp`
///   or a non-admin NAS account, which is the common case;
/// - `ls -la` and a 10 MB `get` in one `sftp` session took 125 ms against 75 ms for `ls -la` alone,
///   so what a download costs is its bytes. That is why the fetch is bounded by the Settings limit.
///
/// It runs only when the stat found nothing, so it never asks where the stat would not have, and a
/// fetch or comparison that fails leaves the save where the stat put it.
public struct WriteBackContentCheck: Sendable {
    /// The backend the checked files belong to.
    public let backend: any VFSBackend
    /// The Settings ▸ Panels limit, which bounds what comes down unasked.
    public let previewLimit: Int64
    /// A local directory the downloads may use. Each lands in a directory of its own under it and is
    /// removed once compared.
    public let scratch: URL

    public init(backend: any VFSBackend, previewLimit: Int64, scratch: URL) {
        self.backend = backend
        self.previewLimit = previewLimit
        self.scratch = scratch
    }

    /// Compare the server's bytes for `current` with `base` when the size and time are all that say
    /// the file is unchanged since `recorded`.
    ///
    /// - Parameters:
    ///   - recorded: the revision the copy is checked against, or `nil` when nothing was recorded.
    ///   - current: the server's file as the save's re-`stat` just read it, or `nil` when it could not.
    ///   - base: the server's bytes at `recorded`, or `nil` when none is kept.
    public func verdict(
        recorded: RemoteFileRevision?,
        current: FileEntry?,
        base: URL?
    ) -> WriteBackContentVerdict {
        guard let recorded, let current,
              recorded.matchesOnlyBySizeAndTime(RemoteFileRevision(current)) else { return .notAsked }
        guard let base else { return .noBase }
        let fetch = RemoteFetchPolicy.decision(
            forByteSize: current.byteSize, purpose: .writeBackCheck, previewLimit: previewLimit
        )
        guard fetch == .fetch else { return .overLimit }
        let landed: MaterializedFile
        do {
            landed = try MaterializeRunner.materialize(
                current, intoDirectory: scratch.path, using: backend
            )
        } catch {
            return .unreadable
        }
        let downloaded = URL(fileURLWithPath: landed.localPath)
        defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
        let equal = try? ByteComparator.localFilesEqual(
            .local(downloaded.path), .local(base.path)
        )
        guard let equal else { return .unreadable }
        return equal ? .same : .different
    }
}
