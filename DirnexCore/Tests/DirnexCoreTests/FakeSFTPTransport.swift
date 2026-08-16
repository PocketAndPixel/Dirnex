import Foundation

@testable import DirnexCore

/// A canned `SFTPTransport`: returns per-path `ls -la` text and records every write call (or throws
/// a configured error), so the backend's browse *and* write logic is exercised without a live
/// server (PLAN.md §2 "the app is a thin client").
final class FakeSFTPTransport: SFTPTransport, @unchecked Sendable {
    var listings: [String: String] = [:]
    var error: SFTPTransportError?

    // Recorded write calls, in the order the backend issued them.
    private(set) var madeDirectories: [String] = []
    private(set) var renames: [(String, String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [String] = []
    private(set) var symlinks: [(link: String, target: String)] = []
    private(set) var downloads: [RecordedTransfer] = []
    /// Transfers this fake was asked to abandon — the record that makes the cancellation rule
    /// assertable at all. A real transport polls `isCancelled` *while the bytes move*, which a
    /// headless double cannot reproduce; what it can pin is that the backend hands the flag down to
    /// the transfer verb instead of only checking it at the file boundary, which is exactly the gap
    /// measured 2026-08-14 (docs/NOTES.md ▸ curl for S3).
    private(set) var cancelledTransfers: [String] = []
    private(set) var uploads: [RecordedTransfer] = []

    /// One recorded `get`/`put`, carrying both endpoints and the resume flag (a struct rather than a
    /// tuple to stay under SwiftLint's two-member `large_tuple` limit).
    struct RecordedTransfer {
        let local: String
        let remote: String
        let resume: Bool
    }

    // Byte counts the transfer methods report back for progress accounting.
    var downloadBytes: Int64 = 0
    var uploadBytes: Int64 = 0

    func listDirectory(_ remotePath: String) throws -> String {
        if let error { throw error }
        return listings[remotePath] ?? ""
    }

    /// What an SSH exec channel answers, or `nil` for an account that has none — the protocol's own
    /// default, and the state every test that does not opt in is in.
    var commandOutput: String?
    /// Thrown instead of answering, for the two shapes that reach the backend differently: a
    /// transport failure (degrade to the walk) and a `CancellationError` (travel out).
    var commandError: Error?
    private(set) var commands: [String] = []

    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? {
        if let commandError { throw commandError }
        commands.append(command)
        return commandOutput
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

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        if let error { throw error }
        symlinks.append((remotePath, target))
    }

    func download(
        _ remotePath: String,
        to localPath: String,
        resume: Bool,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        if isCancelled() { cancelledTransfers.append(remotePath); throw CancellationError() }
        if let error { throw error }
        downloads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return downloadBytes
    }

    func upload(
        _ localPath: String,
        to remotePath: String,
        resume: Bool,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        if isCancelled() { cancelledTransfers.append(remotePath); throw CancellationError() }
        if let error { throw error }
        uploads.append(RecordedTransfer(local: localPath, remote: remotePath, resume: resume))
        return uploadBytes
    }
}
