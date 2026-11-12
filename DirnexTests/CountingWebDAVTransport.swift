import DirnexCore
import Foundation

/// A ``WebDAVTransport`` that forwards to the real one and writes down every request it sent.
///
/// A lock rather than an actor because the protocol is synchronous, as ``InMemorySecretStore``
/// argues for its own.
final class CountingWebDAVTransport: WebDAVTransport, @unchecked Sendable {
    /// One request, by method, with what a test asserts about it.
    enum Request: Equatable, Sendable {
        case propfind(WebDAVDepth)
        case propfindBatch(folders: Int)
        /// A `Depth: 0` PROPFIND naming the quota alone (``WebDAVBackend/quota()``).
        case propfindQuota
        case get(resume: Bool)
        /// One `curl` carrying this many guarded ranges of one file.
        case getRanges(Int)
        case mkcol
        /// A PUT of a local file, and whether it asked the server for a date.
        case put(S3WriteCondition, askedForDate: Bool = false)
        case putEmpty(S3WriteCondition)
        /// Which ends were named with their slash, which only a redirect asks for.
        case move(WebDAVCollectionEnds = [])
        case copy(WebDAVCollectionEnds = [])
        case delete(asCollection: Bool = false)
    }

    private let base: any WebDAVTransport
    private let lock = NSLock()
    private var log: [Request] = []

    init(_ base: any WebDAVTransport) {
        self.base = base
    }

    /// Every request so far, in order.
    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Forget what was sent, so a test counts only the gesture it is about.
    func reset() {
        lock.lock()
        log.removeAll()
        lock.unlock()
    }

    private func record(_ request: Request) {
        lock.lock()
        log.append(request)
        lock.unlock()
    }

    func propfind(_ backendPath: String, depth: WebDAVDepth, isCollection: Bool) throws
        -> WebDAVHTTPResponse {
        record(.propfind(depth))
        return try base.propfind(backendPath, depth: depth, isCollection: isCollection)
    }

    func propfindBatch(_ backendPaths: [String], isCancelled: () -> Bool) throws
        -> [WebDAVBatchAnswer] {
        record(.propfindBatch(folders: backendPaths.count))
        return try base.propfindBatch(backendPaths, isCancelled: isCancelled)
    }

    func propfindQuota(_ backendPath: String) throws -> WebDAVHTTPResponse {
        record(.propfindQuota)
        return try base.propfindQuota(backendPath)
    }

    func download(
        _ backendPath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        record(.get(resume: resume))
        return try base.download(
            backendPath,
            to: localPath,
            resume: resume,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    /// Forwarded rather than left to the protocol's default, which would answer with one plain GET
    /// and hide every split from the count.
    func downloadSegments(
        _ segments: [DownloadSegment],
        of file: WebDAVTaggedFile,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVSegmentedDownload {
        record(.getRanges(segments.count))
        return try base.downloadSegments(
            segments,
            of: file,
            to: localPath,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func mkcol(_ backendPath: String) throws -> WebDAVHTTPResponse {
        record(.mkcol)
        return try base.mkcol(backendPath)
    }

    func upload(
        localPath: String,
        to backendPath: String,
        headers: WebDAVPutHeaders,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> WebDAVHTTPResponse {
        record(.put(headers.condition, askedForDate: headers.modificationTime != nil))
        return try base.upload(
            localPath: localPath,
            to: backendPath,
            headers: headers,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func putEmpty(_ backendPath: String, condition: S3WriteCondition) throws -> WebDAVHTTPResponse {
        record(.putEmpty(condition))
        return try base.putEmpty(backendPath, condition: condition)
    }

    func move(
        _ backendPath: String,
        to destinationPath: String,
        collections: WebDAVCollectionEnds
    ) throws -> WebDAVHTTPResponse {
        record(.move(collections))
        return try base.move(backendPath, to: destinationPath, collections: collections)
    }

    func copy(
        _ backendPath: String,
        to destinationPath: String,
        collections: WebDAVCollectionEnds
    ) throws -> WebDAVHTTPResponse {
        record(.copy(collections))
        return try base.copy(backendPath, to: destinationPath, collections: collections)
    }

    func delete(_ backendPath: String, isCollection: Bool) throws -> WebDAVHTTPResponse {
        record(.delete(asCollection: isCollection))
        return try base.delete(backendPath, isCollection: isCollection)
    }
}
