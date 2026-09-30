import DirnexCore
import Foundation

/// The segmented upload: **N `sftp` children at once**, each sending one part of the file under a
/// name of its own, for the server to join afterwards (PLAN.md §4 ▸ *Still open*).
///
/// The mirror of ``SFTPProcessTransport/downloadSegments(_:of:to:progress:isCancelled:)`` and, unlike
/// it, *ordinary SFTP*: each child runs the `put` this transport has always run, over a slice the
/// core cut. Only the join needs the exec channel, and the caller has already asked for one before
/// anything reaches here — which is the whole difference in cost between the two directions, since a
/// refusal discovered late would waste the upload rather than a download.
///
/// **What keeps it small is that nothing is drained.** Each child's batch command is a few bytes of
/// stdin, and its stdout and stderr are its own *files* beside the slice — so there is no pipe that
/// can fill and no two-pipe deadlock to reason about. What is left is N spawns joined into one
/// `DispatchGroup`, one `ProcessWaiting.wait`, and one `terminate()` each on cancel.
///
/// Progress is **a part at a time**, read from the children exiting. That is the finest granularity
/// this protocol allows and it is the second thing splitting buys: `sftp` prints no meter a spawned
/// process can read, so a single-stream upload can only report once at the very end
/// (``SFTPTransport/upload(_:to:resume:progress:isCancelled:)``), where a split one reports as each
/// part lands.
extension SFTPProcessTransport {
    /// Yes: the children below are spawned before any of them is waited on.
    ///
    /// Asserted by a test rather than left to the reader, because it is the one thing about this
    /// route that nothing else can see — the protocol's sequential default reports progress per part
    /// exactly as this does, so a build that lost this file would keep every assertion green and
    /// silently upload in one connection at a time (docs/NOTES.md ▸ Design lessons).
    var sendsPartsConcurrently: Bool { true }

    @discardableResult
    func uploadParts(
        _ parts: [UploadSegment],
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws -> Int64 {
        guard !parts.isEmpty else { return 0 }

        var children: [Child] = []
        defer { children.forEach { $0.close() } }

        let group = DispatchGroup()
        for part in parts.sorted(by: { $0.number < $1.number }) {
            let child = try spawn(part)
            children.append(child)
            ProcessWaiting.joinTermination(of: child.process, into: group)
        }

        // A part that has exited has landed, so its bytes are reportable — and only once, which is
        // what the `reported` set is for: `onPoll` runs every turn for the length of the transfer.
        // A nested function rather than a stored closure, since `progress` is non-escaping.
        var reported: Set<Int> = []
        func report() {
            for child in children
                where !reported.contains(child.part.number) && !child.process.isRunning {
                reported.insert(child.part.number)
                progress(child.part.length)
            }
        }

        // A password session keeps its bound; key auth waits as long as the transfer takes, exactly
        // as the single-stream upload does — which is why cancellation has to reach inside rather
        // than ride on a deadline.
        let deadline: DispatchTime = isPasswordAuthentication
            ? .now() + .seconds(passwordTimeout)
            : .distantFuture
        switch ProcessWaiting.wait(
            for: group,
            deadline: deadline,
            isCancelled: isCancelled,
            onPoll: report
        ) {
        case .finished:
            report()
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

        // Unlike the segmented *download*, a nonzero exit here means what it says: a part is one
        // `sftp` batch rather than a shell pipeline, so nothing masks the failing stage. The caller
        // is about to fall back to one stream, whose error is the one worth reporting — this only
        // has to be a failure, not a diagnosis.
        guard children.allSatisfy({ $0.process.terminationStatus == 0 }) else {
            throw SFTPTransportError.failure(Self.diagnosis(children))
        }
        return parts.reduce(0) { $0 + $1.length }
    }

    /// One `sftp` sending one part, with its noise going to files beside the slice rather than to
    /// pipes nobody is draining.
    private func spawn(_ part: UploadSegment) throws -> Child {
        let manager = FileManager.default
        let outputPath = part.localPath + ".out"
        let errorPath = part.localPath + ".err"
        guard manager.createFile(atPath: outputPath, contents: nil),
              manager.createFile(atPath: errorPath, contents: nil),
              let output = FileHandle(forWritingAtPath: outputPath),
              let errors = FileHandle(forWritingAtPath: errorPath) else {
            throw SFTPTransportError.failure(String(
                localized: "Couldn’t make room for the upload.",
                comment: "SFTP failure: a temporary file for one part could not be created."
            ))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = batchArguments
        do {
            process.environment = try childEnvironment()
        } catch {
            output.closeFile()
            errors.closeFile()
            throw error
        }

        // The batch is a few bytes, so this pipe is written and closed before the child can fill
        // anything — the one place a pipe is used here, and the one that cannot deadlock.
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            output.closeFile()
            errors.closeFile()
            throw SFTPTransportError.failure(String(
                localized: "Couldn’t launch sftp.",
                comment: "SFTP failure: the sftp binary could not be spawned."
            ))
        }
        // Never `put -p`: a part is a slice this machine cut moments ago, so its mode and times are
        // the temp file's rather than the source's — and the file the user asked for is the one the
        // server joins, whose carry the backend applies afterwards.
        let command = SFTPBatchCommand.upload(part.localPath, to: part.remotePath, resume: false)
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        try? input.fileHandleForWriting.close()
        return Child(
            part: part,
            process: process,
            output: output,
            errors: errors,
            errorPath: errorPath
        )
    }

    /// The server's own words, from whichever part has something to say. Best effort by
    /// construction: the caller falls back to a single stream whose error is the one actually
    /// reported. Empty is allowed — the core supplies a localized stand-in for `failure("")`.
    private static func diagnosis(_ children: [Child]) -> String {
        for child in children where child.process.terminationStatus != 0 {
            let text = (try? String(contentsOfFile: child.errorPath, encoding: .utf8)) ?? ""
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            if !line.isEmpty { return line }
        }
        return ""
    }

    /// One running part, and the two handles that have to be closed whatever happens.
    private struct Child {
        let part: UploadSegment
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
