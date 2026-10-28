import Foundation

/// The write half's requests (PLAN.md §M32 Slice 4): one request per verb, each in the spelling that
/// cannot destroy something nobody chose to replace.
///
/// Probed 2026-10-23 against macOS's Apache `mod_dav` before any of this was written, on top of what
/// Slice 1 measured on the NAS:
///
/// - **MKCOL** answers 201, 405 when anything is already there and 409 when the parent is missing,
///   with or without a trailing slash.
/// - **PUT** answers 201 new and 204 replaced. With `If-None-Match: *` it answers 412 onto a file,
///   but **409 onto a folder** ("Cannot PUT to a collection"), the same status as a missing parent.
/// - **MOVE and COPY** with `Overwrite: F` answer 412 onto anything already there, the same name
///   included, and MOVE into itself 403. A missing destination folder answered **409** to COPY and
///   **500** to MOVE.
/// - **DELETE** of a folder is one request and 204, with or without its slash.
/// - **A cancelled PUT changes nothing.** Apache writes into a temporary file and renames it at the
///   end: a 64 MiB upload killed part-way left no file behind, and one killed over an existing file
///   left that file's bytes as they were. So a stopped upload is never followed by a DELETE, which
///   over a write-back would remove the user's file.
public extension WebDAVProcessArguments {
    /// Create one folder. The URL ends in `/`, which RFC 4918 recommends for a collection and Apache
    /// accepts either way.
    static func mkcol(session: WebDAVSession, backendPath: String) -> [String] {
        common(session: session) + ["-X", "MKCOL", url(session, backendPath, isCollection: true)]
    }

    /// Upload one local file over whatever is at `backendPath`, unless `condition` says otherwise.
    ///
    /// **The URL never ends in `/`**, because `curl -T` against one that does appends the local
    /// file's basename (NOTES.md ▸ curl for S3) — the file would land under a name nobody chose.
    /// A file URL never carries the slash (``WebDAVLocation/url(forBackendPath:isCollection:host:)``).
    ///
    /// No `--fail`: the body of a refusal is part of the classification, for the reason
    /// ``common(session:showingProgress:)`` gives. `curl`'s meter is on, since an upload's only
    /// progress is `curl`'s own percentage.
    ///
    /// **A refused precondition costs a round trip, not the file, above 1 MiB.** `curl` sends
    /// `Expect: 100-continue` only for a body larger than 1 MiB (measured on 8.7.1: 1 048 576 bytes
    /// were sent whole and refused, 1 048 577 sent nothing), and Apache answers the precondition
    /// there: a 64 MiB upload with `If-None-Match: *` onto an existing file reported
    /// `size_upload=0` in 0.4 ms, and one with a stale `If-Match` the same.
    ///
    /// `modificationTime` asks the server to give the file that date (``WebDAVModificationTime``),
    /// which only Nextcloud and ownCloud do, and which the answer then says.
    static func upload(
        session: WebDAVSession,
        localPath: String,
        backendPath: String,
        condition: S3WriteCondition = .unconditional,
        modificationTime: Date? = nil
    ) -> [String] {
        common(session: session, showingProgress: true) + condition.headerArguments
            + WebDAVModificationTime.headerArguments(for: modificationTime)
            + ["--upload-file", localPath, url(session, backendPath, isCollection: false)]
    }

    /// Write an empty file — what ⇧F4's "Edit File…" creates for a name that is not taken.
    ///
    /// `--data-binary ""` states `Content-Length: 0`, for the reason S3's empty object uses it:
    /// `-T /dev/null` is not a regular file, so `curl` falls back to a chunked body (the write-out
    /// counted 5 bytes of framing for an empty file, measured on Apache), which a server that wants a
    /// length may refuse. `Content-Type:` with nothing after it removes the
    /// `application/x-www-form-urlencoded` that `--data-binary` would otherwise label the file with.
    static func putEmpty(
        session: WebDAVSession,
        backendPath: String,
        condition: S3WriteCondition = .unconditional
    ) -> [String] {
        common(session: session) + condition.headerArguments
            + ["-X", "PUT", "--data-binary", "", "-H", "Content-Type:"]
            + [url(session, backendPath, isCollection: false)]
    }

    /// Rename or move one resource on the server — a folder with everything in it, in one request.
    ///
    /// `Overwrite: F` always: an occupied destination answers 412 and nothing moves. A caller that
    /// means to replace something removes it first, as `CopyEngine`'s overwrite path does.
    static func move(session: WebDAVSession, backendPath: String, to destinationPath: String) -> [
        String
    ] {
        transfer("MOVE", session: session, backendPath: backendPath, to: destinationPath)
    }

    /// Duplicate one file on the server. The bytes never come here.
    ///
    /// Only ever a **file**: `CopyEngine` recreates folders itself and copies what is in them one
    /// file at a time, with progress, conflicts and per-item failures. A COPY of a collection would
    /// be RFC 4918's Depth infinity, one request that cannot be followed or stopped.
    static func copy(session: WebDAVSession, backendPath: String, to destinationPath: String) -> [
        String
    ] {
        transfer("COPY", session: session, backendPath: backendPath, to: destinationPath)
    }

    /// Remove one resource — a folder with everything in it, in one request. The body is read: a
    /// folder holding a locked file answers 424 and names that file (PLAN.md §M32).
    static func delete(session: WebDAVSession, backendPath: String) -> [String] {
        common(session: session) + ["-X", "DELETE", url(session, backendPath, isCollection: false)]
    }

    /// MOVE and COPY share their shape: the source in the URL, the destination as an **absolute URL**
    /// in a header.
    ///
    /// Absolute because the NAS answered a path-absolute `Destination`, which RFC 4918 allows, with a
    /// bare 400, and macOS's Apache logged it as "Destination URI must be an absolute URI". Both URLs
    /// are built on the dialed host, so they name the same server the same way; Apache compares the
    /// scheme and port of the two (a `Destination` naming `https` on an `http` request answered 502).
    ///
    /// Neither carries a trailing slash, since the caller does not know whether it is moving a file
    /// or a folder. Apache moved a folder named without one (measured).
    private static func transfer(
        _ method: String,
        session: WebDAVSession,
        backendPath: String,
        to destinationPath: String
    ) -> [String] {
        common(session: session)
            + ["-X", method]
            + ["-H", "Destination: \(url(session, destinationPath, isCollection: false))"]
            + ["-H", "Overwrite: F"]
            + [url(session, backendPath, isCollection: false)]
    }
}
