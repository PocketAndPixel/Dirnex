import DirnexCore
import Foundation

/// Packs files into a new archive by spawning `bsdtar` — the non-hermetic I/O half of TC's Pack
/// (Alt+F5, PLAN.md §M4 "pack via F5-with-archive-target"), mirroring `ArchiveExtractor` and
/// `ArchiveMounter`. The pure argv comes from `DirnexCore.ArchivePacking`; this runs the process
/// off-main, reports what it is doing, and stops it when asked.
///
/// **It is the queue's `bsdtar`** (PLAN.md §4 ▸ *Smaller than a milestone*): since 2026-08-30 a plain
/// pack is a `FileOperation` like any other, so this conforms to ``DirnexCore/PlainPackWriting`` and
/// is injected into `FileOperationQueue`. The core decides what a pack *is* and what its bar means;
/// everything here is process control, which PLAN.md §2 keeps in the app.
///
/// Unlike extraction, packing writes directly to the path it is given — for a local destination that
/// is the user's own file, and for a remote one a temp build path the runner chose. `bsdtar -c`
/// overwrites any existing file, so the caller resolves a name collision before calling here.
struct ArchivePacker: PlainPackWriting {
    /// How often to ask `bsdtar` what it is doing.
    ///
    /// **The tool prints nothing on its own and no flag turns one on** — what it answers is SIGINFO
    /// (measured; see ``DirnexCore/BsdtarProgress``). Every fourth 100 ms poll is about 2.5 asks a
    /// second, which is more than a bar can show and far less than the once-per-poll version, whose
    /// cost is two lines of stderr per ask for however many minutes the pack runs.
    private static let asksPerPoll = 4

    func pack(
        _ request: PlainPackRequest,
        onProgress: @escaping @Sendable (BsdtarProgressSample) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        process.arguments = ArchivePacking.packingArguments(
            archiveOnDiskPath: request.archiveOnDiskPath,
            sources: request.sources,
            format: request.format,
            level: request.level
        )
        // Nothing reads `bsdtar`'s stdout, and discarding it avoids a full-pipe stall. **stderr is a
        // pipe now** rather than `/dev/null`, because that is where a SIGINFO answer lands — and it
        // is drained on a queue of its own, since a pipe nobody empties wedges the process.
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors

        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        let answers = BsdtarAnswers()
        drain(errors, into: answers, group: group)

        do {
            try process.run()
        } catch {
            throw VFSError.unsupported(.archiveToolUnavailableForCreate)
        }

        var polls = 0
        let outcome = ProcessWaiting.wait(
            for: group,
            // No deadline: a pack of a large tree is legitimately minutes, and a plain pack has
            // never had one. What it has instead — and did not before this slice — is a Stop.
            deadline: .distantFuture,
            isCancelled: isCancelled
        ) {
            polls += 1
            guard polls % Self.asksPerPoll == 0 else { return }
            // Ask first, read second: the answer to *this* signal arrives while the next poll is
            // sleeping, so every update is one turn old. That is a tenth of a second on a bar and
            // it is what keeps the ask off the reading thread.
            kill(process.processIdentifier, SIGINFO)
            if let sample = BsdtarProgress.latestSample(in: answers.text) { onProgress(sample) }
        }

        if outcome == .cancelled {
            process.terminate()
            _ = group.wait(timeout: .now() + .seconds(2))
            // `bsdtar` leaves a partial archive behind on SIGTERM (measured), and a half-written
            // archive is worse than none because it opens.
            try? FileManager.default.removeItem(atPath: request.archiveOnDiskPath)
            throw CancellationError()
        }

        // A non-zero exit or a missing output file means nothing usable landed; clean up a partial
        // archive so the destination isn't left with a broken file.
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: request.archiveOnDiskPath) else {
            try? FileManager.default.removeItem(atPath: request.archiveOnDiskPath)
            let name = (request.archiveOnDiskPath as NSString).lastPathComponent
            throw VFSError.unsupported(.archiveCreateFailed(archive: name))
        }
    }

    /// Empty `pipe` on a queue of its own for as long as the process lives.
    ///
    /// `availableData` rather than `read(upToCount:)`, which is not a chunked read at all: it loops
    /// until it has the count asked for or EOF, so it would hand over every sample at once when the
    /// pack finished — progress that arrives after the work is the bug this whole path exists to
    /// fix, reintroduced one layer down (docs/NOTES.md ▸ curl for S3).
    private func drain(_ pipe: Pipe, into answers: BsdtarAnswers, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                answers.append(chunk)
            }
        }
    }
}

/// What `bsdtar` has said so far, kept to the tail.
///
/// One SIGINFO answer is two lines and a long pack is asked thousands of times, so the whole
/// transcript is a growing buffer nobody reads. Only the newest sample is ever wanted, so anything
/// older than the last few can go — and it must be cut on a **line** boundary, or the trim leaves a
/// half line at the front that the parser would have to be careful about.
private final class BsdtarAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    /// Generous next to the ~120 bytes a sample occupies, and small enough that a pack running for
    /// an hour holds nothing worth mentioning.
    private static let keep = 4096

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func append(_ chunk: Data) {
        guard let text = String(data: chunk, encoding: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer += text
        guard buffer.utf8.count > Self.keep else { return }
        let tail = buffer.suffix(Self.keep / 2)
        buffer = tail.firstIndex(where: \.isNewline).map { String(tail[tail.index(after: $0)...]) }
            ?? String(tail)
    }
}
