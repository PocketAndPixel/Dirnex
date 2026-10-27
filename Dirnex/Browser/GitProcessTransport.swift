import DirnexCore
import Foundation

/// `DirnexCore.GitTransport` over a real `git` process: the non-hermetic half of reading a
/// conflicted file's versions (PLAN.md §M34 Slice 5). What the commands are and what their output
/// means is the core's (`GitCommand`, `GitConflictReader`); this spawns and collects.
///
/// Blocking; call it off the main thread.
struct GitProcessTransport: GitTransport {
    /// The `git` to run, resolved once, shared with the status provider so the two cannot find
    /// different ones. `nil` on a Mac with no real `git`, where no row is badged U either.
    static let executablePath = GitCommand.executablePath {
        FileManager.default.isExecutableFile(atPath: $0)
    }

    func run(_ arguments: [String]) throws(GitRunFailure) -> Data {
        guard let executablePath = Self.executablePath else {
            throw GitRunFailure(status: nil, message: "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let group = DispatchGroup()
        ProcessWaiting.joinTermination(of: process, into: group)
        do {
            try process.run()
        } catch {
            // The termination handler never fires for a process that did not start, so nothing
            // waits on the group here.
            throw GitRunFailure(status: nil, message: error.localizedDescription)
        }
        // Both pipes drain at once, since git blocks writing to whichever one is full: standard
        // error on a queue of its own, joined with the exit, and standard output on this thread.
        let message = CollectedOutput()
        group.enter()
        ProcessWaiting.pipeQueue("com.dirnex.git.errors").async {
            defer { group.leave() }
            message.set(errors.fileHandleForReading.readDataToEndOfFile())
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        guard process.terminationStatus == 0 else {
            throw GitRunFailure(
                status: process.terminationStatus,
                // swiftlint:disable:next optional_data_string_conversion
                message: String(decoding: message.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return data
    }
}

/// What a drain read, handed from its queue to the thread that waited for it.
private final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var collected = Data()

    var data: Data {
        lock.withLock { collected }
    }

    func set(_ data: Data) {
        lock.withLock { collected = data }
    }
}
