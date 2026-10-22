import Foundation

/// The HTTP methods the WebDAV backend sends. A status means different things on different
/// methods — a 405 on MKCOL is a folder that already exists, and on anything else a server that
/// will not do it — so the method travels with every refusal (``WebDAVServiceError``).
///
/// LOCK, UNLOCK and PROPPATCH are absent on purpose: Dirnex takes no locks of its own and carries no
/// times, since the one time property a client would set is read-only (PLAN.md §M32).
public enum WebDAVMethod: String, Sendable, Equatable, CaseIterable {
    case options = "OPTIONS"
    case propfind = "PROPFIND"
    case head = "HEAD"
    case get = "GET"
    case put = "PUT"
    case mkcol = "MKCOL"
    case delete = "DELETE"
    case copy = "COPY"
    case move = "MOVE"

    /// Whether the method creates a resource at a path, and so may be refused because the folder
    /// that path is in does not exist (RFC 4918's 409), or because something is already there.
    var createsResource: Bool {
        switch self {
        case .put, .mkcol, .copy, .move: true
        case .options, .propfind, .head, .get, .delete: false
        }
    }
}

/// Why a WebDAV request failed, read from the response rather than from `curl`'s exit status.
///
/// HTTP inverts FTP's rule, as ``S3ResponseError`` records for S3: `curl` exits 0 for a 404, a 423
/// and a 401 alike, so the classification lives in the status and, for an operation on a folder,
/// in the multistatus body. The exit code answers only whether a server answered at all.
public enum WebDAVResponseError: Error, Sendable, Equatable {
    /// The request never got an answer.
    case transport(WebDAVTransportFailure)
    /// The server answered, and said no.
    case service(WebDAVServiceError)
}

/// A failure below HTTP, named by `curl`'s exit code.
public enum WebDAVTransportFailure: Int32, Sendable, Equatable {
    case couldNotResolveHost = 6
    case couldNotConnect = 7
    case operationTimedOut = 28
    /// The certificate did not verify — on the NAS, Synology's self-signed one, which is the same
    /// certificate its FTPS presents (measured 2026-10-22), so the FTPS trust flow applies.
    case certificateNotTrusted = 60
    /// `CURLE_SSL_PINNEDPUBKEYNOTMATCH`: a pinned key was weighed and rejected, before any data
    /// moved. It cannot arise without `--pinnedpubkey`, so it always means "not the certificate you
    /// trusted" (NOTES.md ▸ FTPS trust).
    case pinnedKeyMismatch = 90
    /// Anything else `curl` reported.
    case other = -1

    public static func classify(curlExit code: Int32) -> WebDAVTransportFailure {
        WebDAVTransportFailure(rawValue: code) ?? .other
    }
}

/// The server's refusal: the status, the method it refused, and the members a multistatus body
/// named.
public struct WebDAVServiceError: Sendable, Equatable {
    /// The HTTP status line's code.
    public let status: Int
    /// The method that was refused.
    public let method: WebDAVMethod
    /// The resources a multistatus body names with their own status — for a DELETE, COPY or MOVE of
    /// a folder, the members it could not act on. Empty for an HTML error page, which is what the
    /// NAS sends for every refusal that is not about members.
    ///
    /// This is the outcome, and the status is not. Measured on the NAS 2026-10-22: a DELETE of a
    /// folder holding a locked file answers **424 Failed Dependency**, deletes nothing, and names
    /// the locked file here as 423. A reader of the status alone sees neither a 207 nor a 423.
    public let members: [WebDAVResponse]

    public init(status: Int, method: WebDAVMethod, members: [WebDAVResponse] = []) {
        self.status = status
        self.method = method
        self.members = members
    }
}

public extension WebDAVServiceError {
    /// Read a refusal. A body that is not a multistatus document — Apache's HTML pages, an empty
    /// body, a proxy's answer — still classifies by its status, with no members.
    static func parse(_ data: Data, status: Int, method: WebDAVMethod) -> WebDAVServiceError {
        let members = (try? WebDAVMultistatusParser.parse(data))?.responses.filter { response in
            guard let status = response.status else { return false }
            return !(200...299).contains(status)
        } ?? []
        return WebDAVServiceError(status: status, method: method, members: members)
    }

    /// The status that says what went wrong: the server's own, unless it is the one that defers to
    /// the members (207 and 424), in which case the first locked member's, or failing that the
    /// first member's.
    var effectiveStatus: Int {
        guard status == 207 || status == 424 else { return status }
        return members.first(where: { $0.status == 423 })?.status
            ?? members.first?.status
            ?? status
    }

    /// Whether the credentials were refused, which the connect flow answers by asking for them
    /// again rather than by reporting.
    var isCredentialFailure: Bool { status == 401 }

    /// Whether a lock held by someone else is what refused this: a 423 on the resource itself, or
    /// on a member of a folder (the 424 above).
    var isLocked: Bool { effectiveStatus == 423 }

    /// The members a body named as locked, as decoded server paths.
    var lockedMemberPaths: [String] {
        members.filter { $0.status == 423 }.map(\.path)
    }

    /// Whether a condition the request carried did not hold: `Overwrite: F` or
    /// `If-None-Match: *` against something already there, or `If-Match` against a tag that is no
    /// longer the resource's. The request knows which it sent, so a write-back sending `If-Match`
    /// reads this before ``vfsError(for:destination:)``, whose mapping is the other two's.
    var isPreconditionFailed: Bool { status == 412 }

    /// The closest `VFSError`.
    ///
    /// `path` is the resource the request named, and `destination` the `Destination` of a COPY or
    /// MOVE. A 409 or 412 is about the place being created, so for those two methods it reports
    /// the destination — a missing *source* is a 404 and reports `path`.
    ///
    /// A lock maps to `EBUSY` for now. Its own sentence, naming the file as locked by someone else
    /// rather than as unreadable, needs a `VFSUnsupportedReason` and a translation in every
    /// language, and arrives with the write half (PLAN.md §M32 Slice 4), which is where a 423 can
    /// first happen: a lock is a write lock, and reading and listing pass it.
    func vfsError(for path: VFSPath, destination: VFSPath? = nil) -> VFSError {
        let created = (method == .copy || method == .move) ? destination ?? path : path
        switch effectiveStatus {
        case 401, 403:
            return .permissionDenied(path)
        case 404:
            return .notFound(path)
        // MKCOL's 405 is RFC 4918's "already exists". On any other method it is a server that does
        // not do this at all, which no case below names better than an I/O error.
        case 405 where method == .mkcol:
            return .alreadyExists(path)
        // RFC 4918's 409 for a method that creates is "the folder this goes in does not exist"
        // (measured on MKCOL), so it names that folder rather than the thing being created.
        case 409 where method.createsResource:
            return .notFound(created.parent ?? created)
        case 412:
            return .alreadyExists(created)
        case 413:
            return .io(path: created, code: EFBIG)
        case 423:
            return .io(path: path, code: EBUSY)
        case 507:
            return .io(path: created, code: ENOSPC)
        default:
            return .io(path: path, code: EIO)
        }
    }
}
