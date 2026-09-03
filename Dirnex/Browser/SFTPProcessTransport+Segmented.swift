import DirnexCore
import Foundation

/// The segmented download: **N `ssh` children at once**, each reading one byte range of the remote
/// file (docs/HISTORY.md ▸ After M19).
///
/// This is the one place in the project where a transfer is more than one child, and it is not a
/// preference. The system `curl` speaks no `sftp`, so there is no `-Z` to hand a list of ranges to;
/// `sftp(1)` has no range verb at all. The remote half is ``SSHSegmentCommand`` over an exec
/// channel, and the near half is this — so the concurrency the S3 and FTP halves were designed to
/// avoid lands here, deliberately and bounded (four children, by
/// ``SegmentedDownloadLimits/sftp``).
///
/// **What keeps it small is that nothing is piped.** Each child's stdout is its own *file* — the
/// piece — and its stderr is a small file beside it, so there is no pipe that can fill and no drain
/// to run: the two-pipe deadlock this project documents everywhere else simply has no shape here.
/// What is left is N spawns joined into one `DispatchGroup`, one `ProcessWaiting.wait` for all of
/// them, and one `terminate()` each on cancel. Progress is the pieces growing, which is exact and
/// free (``TransferProgressWatch/Source/destinationFiles(paths:totalBytes:)``).
extension SFTPProcessTransport {
    @discardableResult
    func downloadSegments(
        _ segments: [DownloadSegment],
        of remotePath: String,
        to localPath: String,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> SegmentedDownloadOutcome {
        guard !segments.isEmpty else { return .segments(bytes: 0) }

        let environment = isPasswordAuthentication ? try passwordEnvironment() : nil
        var children: [Child] = []
        // Built before anything is spawned, so the watch's baseline is read while every piece is
        // still empty — and torn down on every exit path, including the throwing ones.
        let watch = TransferProgressWatch(.destinationFiles(
            paths: segments.map(\.localPath),
            totalBytes: segments.reduce(0) { $0 + $1.length }
        ))
        defer { children.forEach { $0.close() } }

        let group = DispatchGroup()
        for segment in segments {
            let child = try spawn(segment, of: remotePath, environment: environment)
            children.append(child)
            ProcessWaiting.joinTermination(of: child.process, into: group)
        }

        // One wait for all of them. A password session keeps its bound; key auth waits as long as
        // the transfer takes, exactly as the single-stream download does — which is why cancellation
        // has to reach inside rather than ride on a deadline.
        let deadline: DispatchTime = isPasswordAuthentication
            ? .now() + .seconds(passwordTimeout)
            : .distantFuture
        switch ProcessWaiting.wait(
            for: group,
            deadline: deadline,
            isCancelled: isCancelled,
            onPoll: { watch.report(to: progress) }
        ) {
        case .finished:
            break
        case .cancelled:
            children.forEach { $0.process.terminate() }
            group.wait()
            throw CancellationError()
        case .timedOut:
            children.forEach { $0.process.terminate() }
            group.wait()
            throw SFTPTransportError.failure(String(
                localized: "The SFTP server stopped responding.",
                comment: "SFTP failure: the server held the channel open past the timeout."
            ))
        }

        // `ssh` exits 255 when it could not connect or authenticate at all, and otherwise carries
        // the remote command's status — which for a pipeline is its **last** stage's, so a `tail`
        // that could not open the file comes back as 0 with an empty piece. That is why a nonzero
        // exit is treated as a failure of the whole run and a zero one proves nothing: the lengths
        // are the evidence, and `SegmentAssembly` weighs them (``SSHSegmentCommand``).
        guard children.allSatisfy({ $0.process.terminationStatus == 0 }) else {
            throw SFTPTransportError.failure(Self.diagnosis(children))
        }
        return .segments(bytes: segments.reduce(0) { $0 + Self.fileSize($1.localPath) })
    }

    /// One `ssh` reading one range, with its bytes going straight to the piece and its noise to a
    /// file beside it.
    private func spawn(
        _ segment: DownloadSegment,
        of remotePath: String,
        environment: [String: String]?
    ) throws -> Child {
        let manager = FileManager.default
        let errorPath = segment.localPath + ".err"
        guard manager.createFile(atPath: segment.localPath, contents: nil),
              manager.createFile(atPath: errorPath, contents: nil),
              let output = FileHandle(forWritingAtPath: segment.localPath),
              let errors = FileHandle(forWritingAtPath: errorPath) else {
            throw SFTPTransportError.failure(String(
                localized: "Couldn’t make room for the download.",
                comment: "SFTP failure: a temporary file for one piece could not be created."
            ))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = execArguments(
            command: SSHSegmentCommand.read(remotePath, range: segment.range)
        )
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            output.closeFile()
            errors.closeFile()
            throw SFTPTransportError.failure(String(
                localized: "Couldn’t launch ssh.",
                comment: "SFTP failure: the ssh binary could not be spawned."
            ))
        }
        return Child(process: process, output: output, errors: errors, errorPath: errorPath)
    }

    /// The server's own words, from whichever piece has something to say.
    ///
    /// Best effort by construction: the caller falls back to a single stream whose error is the one
    /// actually reported, so this is only ever read if that also fails. Empty is allowed — the core
    /// supplies a localized stand-in for `failure("")`, which is the rule that keeps the transport
    /// from authoring sentences it cannot translate.
    private static func diagnosis(_ children: [Child]) -> String {
        for child in children where child.process.terminationStatus != 0 {
            let text = (try? String(contentsOfFile: child.errorPath, encoding: .utf8)) ?? ""
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if !line.isEmpty { return line }
        }
        return ""
    }

    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int64 else { return 0 }
        return size
    }

    /// One running segment, and the two handles that have to be closed whatever happens — a leaked
    /// write handle keeps the piece open and its size unsettled, which is exactly what the assembly
    /// then measures.
    private struct Child {
        let process: Process
        let output: FileHandle
        let errors: FileHandle
        let errorPath: String

        func close() {
            try? output.close()
            try? errors.close()
        }
    }
}
