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

    private(set) var listedPaths: [String] = []
    private(set) var madeDirectories: [String] = []
    private(set) var renames: [(String, String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [String] = []
    private(set) var fileSizeQueries: [String] = []
    private(set) var downloads: [RecordedTransfer] = []
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

    func download(_ remotePath: String, to localPath: String, resume: Bool) throws -> Int64 {
        if let error { throw error }
        downloads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return transferBytes
    }

    func upload(_ localPath: String, to remotePath: String, resume: Bool) throws -> Int64 {
        if let error { throw error }
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
