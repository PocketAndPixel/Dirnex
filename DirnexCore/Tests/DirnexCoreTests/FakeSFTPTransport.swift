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
    private(set) var createdFiles: [String] = []
    private(set) var renames: [(String, String)] = []
    private(set) var removedFiles: [String] = []
    private(set) var removedDirectories: [String] = []
    private(set) var symlinks: [(link: String, target: String)] = []
    private(set) var downloads: [RecordedTransfer] = []
    /// The bytes a segmented download serves its ranges out of. `nil` is an empty file, which only a
    /// test that does not care about the bytes should leave it as.
    var fileBytes: Data?
    /// Answers every segment with the prose an `sftp`-only account sends **instead of** the bytes —
    /// exit 1, on stdout, where a piece's data would go. The commonest refusal on this route, and
    /// the one that arrives looking like a very short file rather than like an error.
    var hasNoExecChannel = false
    /// Serves every segment the **whole** file rather than its range.
    var ignoresRanges = false
    /// Every segmented download the backend asked for, in call order — the requests rather than
    /// their numbers, so a test can ask whether the files this run was given still exist.
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

    /// Deltas a transfer reports *while it runs*, standing in for the destination file growing.
    /// Empty is what an upload really does here — `sftp` gives one no observable at all — and is
    /// therefore the default rather than a convenience.
    var streamedProgress: [Int64] = []

    // MARK: - Metadata carry (PLAN.md §M25 Slice 2)

    /// What this double claims it can carry. **`[]` by default**, which is the whole point: a
    /// transport that has not implemented the carry must make the backend plan nothing and *report*
    /// the loss rather than claim a mode it never wrote. Every test written before this milestone
    /// therefore keeps measuring exactly what it always did.
    var metadataCapabilities: RemoteMetadataCapabilities = []
    /// The plan each transfer was handed, in call order — the observable that says whether the
    /// backend asked for the carry at all, as opposed to whether the file ended up right.
    private(set) var carriedPlans: [RemoteMetadataPlan] = []
    /// Steps handed to ``applyMetadata(_:to:)``, with the path they were aimed at.
    private(set) var appliedMetadata: [(path: String, steps: [RemoteMetadataStep])] = []
    /// What every metadata step will answer. Empty is "it all arrived".
    var metadataRefusals: [RemoteMetadataRefusal] = []

    func download(
        _ remotePath: String,
        to localPath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome {
        carriedPlans.append(options.carry)
        let bytes = try download(
            remotePath,
            to: localPath,
            resume: options.resume,
            progress: progress,
            isCancelled: isCancelled
        )
        return RemoteTransferOutcome(bytes: bytes, refusals: metadataRefusals)
    }

    func upload(
        _ localPath: String,
        to remotePath: String,
        options: RemoteTransferOptions,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> RemoteTransferOutcome {
        carriedPlans.append(options.carry)
        let bytes = try upload(
            localPath,
            to: remotePath,
            resume: options.resume,
            progress: progress,
            isCancelled: isCancelled
        )
        return RemoteTransferOutcome(bytes: bytes, refusals: metadataRefusals)
    }

    /// Whether this double's server offers OpenSSH's `copy-data` extension. **Off by default**, the
    /// state every transport that predates the verb is in: `copyRemoteFile` then throws the same
    /// refusal a real server without it produces, which is what the backend latches and the router
    /// stages around.
    var supportsServerSideCopy = false
    /// Every server-side copy this double was asked for, with the plan riding it — the observable
    /// that separates *the route ran* from *the file ended up right*, which no fake can answer.
    private(set) var serverSideCopies: [RecordedServerSideCopy] = []

    struct RecordedServerSideCopy {
        let source: String
        let destination: String
        let carry: RemoteMetadataPlan
    }

    func copyRemoteFile(
        _ source: String,
        to destination: String,
        carrying plan: RemoteMetadataPlan,
        isCancelled: () -> Bool
    ) throws -> [RemoteMetadataRefusal] {
        if isCancelled() { cancelledTransfers.append(source); throw CancellationError() }
        guard supportsServerSideCopy else { throw SFTPTransportError.copyExtensionUnavailable }
        if let error { throw error }
        serverSideCopies.append(
            RecordedServerSideCopy(source: source, destination: destination, carry: plan)
        )
        return metadataRefusals
    }

    func applyMetadata(
        _ steps: [RemoteMetadataStep],
        to remotePath: String
    ) throws -> [RemoteMetadataRefusal] {
        appliedMetadata.append((path: remotePath, steps: steps))
        return metadataRefusals
    }

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

    /// Answers ``SSHAssembleCommand``'s three commands the way a real shell would — joining the
    /// parts this fake is holding, renaming the staging file, and sweeping up — so a test can assert
    /// the **file the server ends up with** rather than only the command that was sent.
    ///
    /// Off unless a test sets it, because every suite that predates segmented uploads must keep
    /// getting the protocol's own default: an account with no exec channel, which declines the whole
    /// route.
    var actsAsShell = false

    func runCommand(_ command: String, isCancelled: () -> Bool) throws -> String? {
        if let commandError { throw commandError }
        commands.append(command)
        // The same account property ``hasNoExecChannel`` names for a segmented download, answered
        // where an exec request goes: prose, on stdout, which is where the answer would have been.
        // Checked ahead of ``actsAsShell`` because an account with no exec channel has no shell to
        // act as, and a fixture that set both would otherwise silently get one.
        if hasNoExecChannel { return "This service allows sftp connections only.\n" }
        guard actsAsShell else { return commandOutput }
        if command.hasPrefix("/usr/bin/env echo ") {
            return Self.words(command).last
        }
        if command.hasPrefix("/usr/bin/env cat ") {
            // `cat 'p1' … 'pN' > 'staging' && wc -c < 'staging'` names the staging file twice.
            let paths = Self.words(command)
            guard let staging = paths.last, paths.count >= 3 else { return "" }
            let joined = paths.dropLast(2).reduce(into: Data()) { $0 += remoteFiles[$1] ?? Data() }
            remoteFiles[staging] = joined
            return "\(joined.count)\n"
        }
        if command.hasPrefix("/usr/bin/env mv ") {
            let paths = Self.words(command)
            if paths.count >= 2 { remoteFiles[paths[1]] = remoteFiles.removeValue(forKey: paths[0]) }
            for path in paths.dropFirst(2) { remoteFiles.removeValue(forKey: path) }
            return ""
        }
        if command.hasPrefix("/usr/bin/env rm ") {
            for path in Self.words(command) { remoteFiles.removeValue(forKey: path) }
            return ""
        }
        return commandOutput
    }

    /// The single-quoted operands of one of ``SSHAssembleCommand``'s commands, in order — enough of
    /// a shell to serve the three shapes it emits, and nothing more.
    private static func words(_ command: String) -> [String] {
        command.split(separator: "'", omittingEmptySubsequences: false)
            .enumerated()
            .filter { $0.offset % 2 == 1 }
            .map { String($0.element) }
    }

    /// Fails **only** `makeDirectory`, leaving listings answerable — the state a real server is in
    /// when it refuses a `mkdir` for a name that is already taken. `error` cannot express it: it
    /// fails every verb, including the `stat` the backend disambiguates with.
    var makeDirectoryError: SFTPTransportError?

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

    func createSymbolicLink(_ remotePath: String, target: String) throws {
        if let error { throw error }
        symlinks.append((remotePath, target))
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
        return downloadBytes
    }

    /// Serve each range out of ``fileBytes`` into the file the segment names, exactly as the real
    /// `ssh` child writes one — which is what lets the assembly, and the bytes it produces, be
    /// asserted with no server.
    ///
    /// ``hasNoExecChannel`` reproduces the shape that has no equivalent on the other two routes: the
    /// server answers, successfully, with something that is not the data — so the pieces exist, are
    /// the wrong length, and nothing threw.
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
        let refusal = Data("This service allows sftp connections only.\n".utf8)
        let contents = fileBytes ?? Data()
        var moved: Int64 = 0
        for segment in segments {
            let served: Data
            if hasNoExecChannel {
                served = refusal
            } else if ignoresRanges {
                served = contents
            } else {
                served = Self.slice(contents, segment.range)
            }
            try? served.write(to: URL(fileURLWithPath: segment.localPath))
            moved += Int64(served.count)
            progress(Int64(served.count))
        }
        return .segments(bytes: moved)
    }

    /// Every batch of parts this fake was asked to send, in call order — the observable that says
    /// whether the backend split the upload at all, and into what.
    private(set) var partBatches: [[UploadSegment]] = []
    /// The part numbers of each batch — the shape a test asserts when it cares about the *plan*
    /// rather than about the bytes.
    var partRuns: [[Int]] { partBatches.map { $0.map(\.number) } }
    /// What the server ends up holding, keyed by remote path: the parts as they land, and — once the
    /// join has been asked for — whatever `cat` produced. Written by the fake's own handling of
    /// ``SSHAssembleCommand``, which is what lets a test assert the *file*, not just the requests.
    private(set) var remoteFiles: [String: Data] = [:]
    /// Makes every part land one byte short, which no `cat` can notice — the quiet failure the
    /// join's size check exists to catch.
    var truncatesParts = false
    /// Fails the *n*th part upload, counting from 1, the way a server out of room would.
    var failsPartNumber: Int?

    /// Run just before a batch is sent — the seam that lets a test read what was on disk, and
    /// what had already been asked of the server, at the moment the parts went out.
    var beforeUploadingParts: (([UploadSegment]) -> Void)?

    @discardableResult
    func uploadParts(
        _ parts: [UploadSegment],
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        beforeUploadingParts?(parts)
        if isCancelled() {
            cancelledTransfers.append(parts.first?.remotePath ?? "")
            throw CancellationError()
        }
        partBatches.append(parts)
        if let error { throw error }
        var moved: Int64 = 0
        for part in parts.sorted(by: { $0.number < $1.number }) {
            if part.number == failsPartNumber { throw SFTPTransportError.failure("no space left") }
            var bytes = (try? Data(contentsOf: URL(fileURLWithPath: part.localPath))) ?? Data()
            if truncatesParts, !bytes.isEmpty { bytes = bytes.dropLast() }
            remoteFiles[part.remotePath] = bytes
            moved += Int64(bytes.count)
            progress(part.length)
        }
        return moved
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
        return uploadBytes
    }
}
