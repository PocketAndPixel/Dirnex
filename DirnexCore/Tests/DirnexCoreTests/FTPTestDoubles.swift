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

    func listDirectory(_ remotePath: String) throws -> String {
        if let error { throw error }
        listedPaths.append(remotePath)
        return listings[remotePath] ?? ""
    }

    func makeDirectory(_ remotePath: String) throws {
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
        return transferBytes
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
