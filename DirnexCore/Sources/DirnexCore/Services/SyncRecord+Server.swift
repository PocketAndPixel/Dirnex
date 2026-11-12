import Foundation

/// What changed since the last sync, on a pair with a server side (PLAN.md §M38 Slice 8).
///
/// The local half is answered by bytes, as on a local pair. The server half is answered by the
/// server row's stamp against the one kept beside the version, so a look over the rows downloads
/// nothing: a file has moved on the server when its size, date or tag has
/// (``RemoteFileRevision/isSuperseded(by:)``).
///
/// **The two halves fail in opposite directions, and the server's in the safe one.** A stamp moves
/// for a `touch`, a restore, or an SFTP file passing six months old, when its listing drops the time
/// of day (docs/NOTES.md ▸ Parsing a year-less timestamp). Each reads as a change with the bytes
/// unchanged, which can only turn a copy into a merge whose server side equals its base, and that
/// merges clean. A stamp stays put only for a write that kept the size inside the listing's
/// resolution: a minute over SFTP, the server's clock over FTP. That edit stays unseen, as it is in
/// the comparison itself, and an entity tag closes it where the server sends one.
public extension SyncRecord {
    /// Which side of the file at `relativePath` changed since the last sync, given the row's two
    /// entries, one on this disk and one on the record's server. Reads the local file only as far as
    /// it has to, and nothing on the server. Blocking; call it off the main thread.
    ///
    /// `.noVersion` when no version is kept, when the version has no server stamp beside it, or when
    /// the row does not have exactly one side on this disk. Throws only `CancellationError`.
    func change(
        of relativePath: String,
        left: FileEntry,
        right: FileEntry,
        isCancelled: () -> Bool = { false }
    ) throws -> SyncChange {
        let localIsLeft: Bool
        switch (left.path.backend == .local, right.path.backend == .local) {
        case (true, false): localIsLeft = true
        case (false, true): localIsLeft = false
        default: return .noVersion
        }
        let (local, server) = localIsLeft ? (left, right) : (right, left)
        guard let stamp = versions[relativePath]?.serverRevision,
              let kept = keptFile(for: relativePath)
        else { return .noVersion }
        let serverMoved = stamp.isSuperseded(by: RemoteFileRevision(server))
        let localMoved: Bool
        do {
            localMoved = try !ByteComparator.localFilesEqual(
                .local(local.path.path),
                .local(kept.path),
                isCancelled: isCancelled
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unreadable
        }
        switch (localMoved, serverMoved) {
        case (false, false): return .unchanged
        case (true, false): return localIsLeft ? .changedOnLeft : .changedOnRight
        case (false, true): return localIsLeft ? .changedOnRight : .changedOnLeft
        case (true, true): return .changedOnBoth(base: kept)
        }
    }
}
