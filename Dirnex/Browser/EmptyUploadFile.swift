import Foundation

/// A zero-byte regular file on this Mac, alive for the length of one call — what both remote
/// transports upload to create an empty file on a server (⇧F4 "Edit File…", PLAN.md §M11).
///
/// **`/dev/null` is the obvious way to spell this and `sftp` refuses it.** Measured 2026-08-23
/// against a real `sshd`: `put /dev/null <remote>` exits 1 with `local "/dev/null" is not a regular
/// file`, so nothing is created. `curl` accepts it over FTP, and libcurl's HTTP side accepts it and
/// then chunk-frames it into a *non*-empty body (docs/NOTES.md ▸ curl for S3) — three protocols,
/// three answers, for one thing that ought to be uniform. A real empty file behaves identically
/// everywhere, so both transports use this rather than each picking what its own tool tolerates.
///
/// The name is deliberately not derived from the remote one. Over SFTP a `put` aimed at an existing
/// *directory* silently creates `<directory>/<this file's basename>` (measured, exit 0) — a state
/// `RemoteTransportBackend.createFile`'s `stat` guard is what prevents, but if it is ever reached
/// the litter should be obviously ours rather than plausibly the user's.
struct EmptyUploadFile {
    /// The scratch file's path, valid until ``remove()``.
    let path: String

    /// Create the file, or throw whatever `FileManager` says about why it could not be written.
    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        path = url.path
    }

    /// Best-effort cleanup: the remote write has already happened or failed by now, and a scratch
    /// file that outlives its call is litter in the temporary directory rather than a failure worth
    /// reporting over the one the caller is already carrying.
    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
