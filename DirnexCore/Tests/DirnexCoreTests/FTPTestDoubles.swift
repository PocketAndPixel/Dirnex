import Foundation
import Testing

@testable import DirnexCore

// MARK: - Test doubles

/// A local file of a known size, so the backend's resume decisions (which read real file lengths)
/// can be exercised without a server.
struct TemporaryFile {
    let path: String

    init(bytes: Int) throws {
        path = NSTemporaryDirectory() + "ftp-test-\(UUID().uuidString)"
        try Data(repeating: 0x41, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

final class FakeFTPTransport: FTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var remoteFileSizes: [String: Int64] = [:]
    var error: FTPTransportError?
    var certificate: FTPCertificate?

    /// What a transfer reports as the bytes it moved — for a resumed transfer, the remainder.
    var transferBytes: Int64 = 0

    /// Deltas a transfer reports *while it runs*, standing in for `curl`'s meter and for a
    /// destination file growing. Empty is the honest default: it is what a transfer that reported
    /// nothing until it exited looks like, which is what this backend did until 2026-08-16.
    var streamedProgress: [Int64] = []

    private(set) var listedPaths: [String] = []
    private(set) var madeDirectories: [String] = []
    private(set) var createdFiles: [String] = []
    private(set) var renames: [(String, String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [String] = []
    private(set) var fileSizeQueries: [String] = []
    private(set) var downloads: [RecordedTransfer] = []
    /// The bytes a segmented download serves its ranges out of. `nil` is an empty file, which only a
    /// test that does not care about the bytes should leave it as.
    var fileBytes: Data?
    /// How many of a run's segments this server will serve before refusing the rest — the shape a
    /// **connection cap** has, which is the commonest way a segmented FTP download fails. `nil`
    /// serves them all.
    var servesAtMostSegments: Int?
    /// Serves every segment the **whole** file rather than its range — a server that ignores `REST`.
    var ignoresRanges = false
    /// Every segmented download the backend asked for, in call order. The *requests* rather than
    /// their numbers, so a test can ask whether the files this run was given still exist rather than
    /// scanning a temp directory it shares with every other test in the process.
    private(set) var segmentRequests: [[DownloadSegment]] = []
    /// The segment numbers of each run — the only place the difference between one stream and
    /// several is visible at all.
    var segmentRuns: [[Int]] { segmentRequests.map { $0.map(\.number) } }
    /// Transfers this fake was asked to abandon — the record that makes the cancellation rule
    /// assertable at all. A real transport polls `isCancelled` *while the bytes move*, which a
    /// headless double cannot reproduce; what it can pin is that the backend hands the flag down to
    /// the transfer verb instead of only checking it at the file boundary, which is exactly the gap
    /// measured 2026-08-14 (docs/NOTES.md ▸ curl for S3).
    private(set) var cancelledTransfers: [String] = []
    private(set) var uploads: [RecordedTransfer] = []

    /// One recorded transfer, carrying both endpoints and the resume flag (a struct rather than a
    /// tuple to stay under SwiftLint's `large_tuple` limit).
    struct RecordedTransfer {
        let local: String
        let remote: String
        let resume: Bool
    }

    /// Directories this server will not list — the ordinary permission gap, which `error` cannot
    /// express because it fails *every* verb. What makes the subtree shortcut's two opposite rules
    /// testable: below the root such a directory is skipped, and at the root it withdraws the
    /// shortcut altogether.
    var unlistablePaths: Set<String> = []
    /// Each batched request, in call order — the only place the difference between "one connection
    /// per level" and "one per directory" is visible at all.
    private(set) var listedBatches: [[String]] = []

    func listDirectory(_ remotePath: String) throws -> String {
        if let error { throw error }
        if unlistablePaths.contains(remotePath) { throw FTPTransportError.permissionDenied }
        listedPaths.append(remotePath)
        return listings[remotePath] ?? ""
    }

    /// The batched listing, answered the way a real one is: one entry per request in order, `nil`
    /// for a directory that could not be listed — never conflated with the empty string an empty
    /// directory gives.
    func listDirectories(_ remotePaths: [String], isCancelled: () -> Bool) throws -> [String?] {
        if let error { throw error }
        guard !isCancelled() else { throw CancellationError() }
        listedBatches.append(remotePaths)
        return remotePaths.map { path in
            guard !unlistablePaths.contains(path) else { return nil }
            listedPaths.append(path)
            return listings[path] ?? ""
        }
    }

    /// Fails **only** `makeDirectory`, leaving listings answerable — the state a real server is in
    /// when it refuses a `mkdir` for a name that is already taken. `error` cannot express it: it
    /// fails every verb, including the `stat` the backend disambiguates with.
    var makeDirectoryError: FTPTransportError?

    func makeDirectory(_ remotePath: String) throws {
        if let makeDirectoryError { throw makeDirectoryError }
        if let error { throw error }
        madeDirectories.append(remotePath)
    }

    func createEmptyFile(_ remotePath: String) throws {
        if let error { throw error }
        createdFiles.append(remotePath)
    }

    func rename(_ source: String, to destination: String) throws {
        if let error { throw error }
        renames.append((source, destination))
    }

    func removeFile(_ remotePath: String) throws {
        if let error { throw error }
        removedFiles.append(remotePath)
    }

    func removeDirectory(_ remotePath: String) throws {
        if let error { throw error }
        removedDirectories.append(remotePath)
    }

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        if isCancelled() { cancelledTransfers.append(remotePath); throw CancellationError() }
        if let error { throw error }
        for delta in streamedProgress { progress(delta) }
        downloads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        // Writes the file when one is set, so a test about *which route ran* can also check that
        // the route it fell back to produced it. Left alone when it is not, which is every test
        // that predates segmented downloads.
        if let fileBytes { try? fileBytes.write(to: URL(fileURLWithPath: localPath)) }
        return transferBytes
    }

    /// Serve each range out of ``fileBytes`` into the file the segment names, exactly as a real
    /// `curl` writes one — which is what lets the assembly, and the bytes it produces, be asserted
    /// with no server.
    ///
    /// The two ways a run can go wrong are switchable rather than hard-coded, because each drives a
    /// different branch: ``servesAtMostSegments`` reproduces a connection cap (some pieces land,
    /// the run fails), and ``ignoresRanges`` a server that sends the whole file to every section.
    @discardableResult
    func downloadSegments(
        _ segments: [DownloadSegment],
        of remotePath: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> SegmentedDownloadOutcome {
        if isCancelled() { cancelledTransfers.append(remotePath); throw CancellationError() }
        segmentRequests.append(segments)
        if let error { throw error }
        let contents = fileBytes ?? Data()
        var moved: Int64 = 0
        for segment in segments {
            if let cap = servesAtMostSegments, segment.number > cap { continue }
            let served = ignoresRanges ? contents : Self.slice(contents, segment.range)
            try? served.write(to: URL(fileURLWithPath: segment.localPath))
            moved += Int64(served.count)
            progress(Int64(served.count))
        }
        if let cap = servesAtMostSegments, cap < segments.count {
            // What a capped server does: it serves what fits and refuses the rest, and the run —
            // one `curl` with one exit code — fails as a whole.
            throw FTPTransportError.failure("421 Too many connections")
        }
        return .segments(bytes: moved)
    }

    private static func slice(_ contents: Data, _ range: Range<Int64>) -> Data {
        let lower = min(Int(range.lowerBound), contents.count)
        let upper = min(Int(range.upperBound), contents.count)
        return contents.subdata(in: lower..<upper)
    }

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        if isCancelled() { cancelledTransfers.append(remotePath); throw CancellationError() }
        if let error { throw error }
        for delta in streamedProgress { progress(delta) }
        uploads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return transferBytes
    }

    // MARK: - Metadata carry (PLAN.md §M25 Slice 2)

    /// What this double claims it can carry. **`[]` by default** — a transport that has not
    /// implemented the carry must make the backend plan nothing and *report* the loss, never claim a
    /// mode it did not write, so every test predating this milestone measures what it always did.
    var metadataCapabilities: RemoteMetadataCapabilities = []
    /// Steps handed to ``applyMetadata(_:to:)``, with the path they were aimed at — the observable
    /// for "the upload asked the server to keep this", which no assertion about the file can make.
    private(set) var appliedMetadata: [(path: String, steps: [RemoteMetadataStep])] = []
    /// What every metadata step will answer. Empty is "it all arrived".
    var metadataRefusals: [RemoteMetadataRefusal] = []

    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        to remotePath: String
    ) throws -> [RemoteMetadataRefusal] {
        appliedMetadata.append((path: remotePath, steps: steps))
        return metadataRefusals
    }

    func fileSize(_ remotePath: String) throws -> Int64 {
        if let error { throw error }
        fileSizeQueries.append(remotePath)
        guard let size = remoteFileSizes[remotePath] else { throw FTPTransportError.notFound }
        return size
    }

    func fetchCertificate() throws -> FTPCertificate {
        if let certificate { return certificate }
        throw FTPTransportError.failure("no certificate")
    }
}
