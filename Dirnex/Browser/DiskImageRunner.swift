import DirnexCore
import Foundation

/// Runs `hdiutil` — the non-hermetic half of a Dirnex vault (PLAN.md §M19 Slice 2).
///
/// The same split every external tool in this app takes: `DirnexCore.DiskImageArguments` builds the
/// argv and `DirnexCore.DiskImageMount` / `DiskImageProgress` read the answers, both pure and tested;
/// this spawns the process, feeds it the passphrase and classifies what came back (PLAN.md §2).
///
/// ## Two rules this file exists to keep
///
/// **The passphrase goes on stdin and nowhere else.** `-stdinpass` is what makes that possible, and
/// ``ArchivePassphrase/withUnsafeBytes(_:)`` is what writes it: the bytes go from the field to the
/// pipe without ever being a `String` anything could log or interpolate. Nothing here builds an
/// argument from a secret, and `DiskImageArguments` has no function that would let it.
///
/// **Exactly those bytes, and no others.** Probed on macOS 26: `hdiutil` takes the whole pipe,
/// verbatim to EOF, as the passphrase — an image created with a trailing newline on stdin refuses to
/// attach without one, and vice versa. Appending a `\n` is the natural thing to do when writing a
/// line to a process and it would make every Dirnex vault permanently un-openable by Disk Utility,
/// Finder, or Dirnex on another Mac, with no way back. So the write is the passphrase's own bytes and
/// then a close, and there is one method on `ArchivePassphrase` that produces exactly that.
///
/// Every entry point blocks on a subprocess, so call them off the main actor.
enum DiskImageRunner {
    private static let executable = URL(fileURLWithPath: "/usr/bin/hdiutil")

    // MARK: - Create

    /// Create a new encrypted vault. Throws ``VaultError/couldNotCreate`` if `hdiutil` refused.
    ///
    /// `onProgress` receives `0.0 ... 1.0` fractions, and **may never be called at all**: measured, a
    /// sparse bundle emits no `PERCENT:` lines whatever ceiling it declares — 100 GB, 500 GB and 2 TB
    /// each took 1.02 s and each cost 34 MB — while a fixed image reports properly, 2 GB in 4.0 s
    /// over six lines. So a caller must treat "no progress yet" as ordinary rather than as a stall,
    /// and the app passes nothing: the only kind it creates finishes before a bar could appear.
    ///
    /// There is deliberately **no cancellation**. A cancel branch here would be unreachable for the
    /// one kind anything creates, and unreachable code that claims to clean up after a half-written
    /// vault is worse than none — it reads as tested. Reading stdout in a loop is not about progress:
    /// a pipe nobody drains fills and stalls the child, which is why the loop exists at all.
    static func create(
        atPath path: String,
        volumeName: String,
        kind: DiskImageArguments.Kind,
        megabytes: Int,
        passphrase: ArchivePassphrase,
        onProgress: (Double) -> Void = { _ in }
    ) throws {
        let arguments = DiskImageArguments.create(
            atPath: path,
            volumeName: volumeName,
            kind: kind,
            megabytes: megabytes
        )
        let run = try Run(arguments: arguments, passphrase: passphrase)

        var trailing = ""
        while let chunk = run.readSomeOutput() {
            trailing += chunk
            // Keep the last partial line back; a read can land mid-number.
            let lines = trailing.split(separator: "\n", omittingEmptySubsequences: false)
            trailing = String(lines.last ?? "")
            for line in lines.dropLast() {
                if case let .fraction(value) = DiskImageProgress.parse(String(line)) {
                    onProgress(value)
                }
            }
        }
        let result = run.finish()

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: path) else {
            // A half-written image is worse than none: it looks like a vault and opens as nothing.
            try? FileManager.default.removeItem(atPath: path)
            throw VaultError.couldNotCreate
        }
    }

    // MARK: - Unlock / lock

    /// Attach `path` and mount its volume, returning where it landed.
    static func attach(atPath path: String, passphrase: ArchivePassphrase) throws
        -> DiskImageMount.Mounted {
        let name = (path as NSString).lastPathComponent
        let run = try Run(
            arguments: DiskImageArguments.attach(atPath: path),
            passphrase: passphrase
        )
        let result = run.drainToEnd()

        guard result.exitCode == 0 else {
            throw VaultError.fromAttachFailure(
                exitCode: result.exitCode,
                stderr: result.errorText,
                name: name
            )
        }
        // An attach reports several entities and only the volume carries a mount point; a plist that
        // parses but names none means the image attached without mounting, which is not an unlock.
        guard let mounted = DiskImageMount.mountPoint(fromAttachPlist: result.output) else {
            throw VaultError.couldNotUnlock
        }
        return mounted
    }

    /// Unmount and detach the volume at `mountPoint`.
    ///
    /// Detaching something already detached exits 1 and is **success** — the user's intent is
    /// satisfied, and `VaultError.fromDetachFailure` is where that judgement lives, so a second Lock
    /// (or a Lock after the user ejected the volume in Finder) does not look broken.
    static func detach(mountPoint: String, name: String) throws {
        let run = try Run(arguments: DiskImageArguments.detach(mountPoint: mountPoint))
        let result = run.drainToEnd()
        if let error = VaultError.fromDetachFailure(
            exitCode: result.exitCode,
            stderr: result.errorText,
            name: name
        ) {
            throw error
        }
    }

    /// Every image `hdiutil` currently has attached — the answer to "is this vault unlocked?".
    ///
    /// Asked rather than remembered, so a `hdiutil detach` in Terminal or an eject in Finder cannot
    /// leave Dirnex showing a vault as open. Returns an empty list if `hdiutil` cannot be run at all,
    /// which reads as "nothing is unlocked" — the safe direction, since the alternative is offering a
    /// Lock for a vault that is not there.
    static func attachedImages() -> [DiskImageMount.AttachedImage] {
        guard let run = try? Run(arguments: DiskImageArguments.info()) else { return [] }
        let result = run.drainToEnd()
        guard result.exitCode == 0 else { return [] }
        return DiskImageMount.attachedImages(fromInfoPlist: result.output)
    }

    // MARK: - One process

    /// What one finished `hdiutil` said.
    struct ProcessResult {
        let exitCode: Int32
        let output: Data
        let errorText: String
    }

    /// A running `hdiutil`, with its passphrase already written and both pipes being drained.
    ///
    /// Both streams have to be read concurrently or a full pipe deadlocks the child (docs/NOTES.md,
    /// learned on `sftp`), so stderr drains on its own queue for the process's whole life and stdout
    /// is left for the caller — which is what lets `create` read progress as it happens while
    /// `attach` simply waits for the plist.
    private final class Run {
        private let process = Process()
        private let output = Pipe()
        private let errorPipe = Pipe()
        private let collectedError = Collector()

        init(arguments: [String], passphrase: ArchivePassphrase? = nil) throws {
            process.executableURL = DiskImageRunner.executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errorPipe

            let input = Pipe()
            process.standardInput = input

            let collector = collectedError
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                collector.append(data)
            }

            do {
                try process.run()
            } catch {
                throw VaultError.couldNotCreate
            }

            // The passphrase, then EOF — and nothing between them. `hdiutil` reads to EOF, so the
            // close is what ends the passphrase; a process given no passphrase (`info`, `detach`)
            // gets the same empty-then-closed pipe rather than an inherited stdin it could block on.
            if let passphrase {
                passphrase.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
                    input.fileHandleForWriting.write(
                        Data(
                            bytesNoCopy: UnsafeMutableRawPointer(mutating: base),
                            count: bytes.count,
                            deallocator: .none
                        )
                    )
                }
            }
            try? input.fileHandleForWriting.close()
        }

        /// The next chunk of standard output, or `nil` once it is closed.
        ///
        /// A chunk can land mid-character as well as mid-line, so an undecodable tail is treated as
        /// nothing rather than as end-of-stream: `hdiutil`'s output is ASCII, and a caller that
        /// stopped reading here would lose the rest of the run.
        func readSomeOutput() -> String? {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { return nil }
            return String(bytes: data, encoding: .utf8) ?? ""
        }

        /// Read every remaining byte of standard output and wait for the process.
        func drainToEnd() -> ProcessResult {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return finish(output: data)
        }

        /// Wait for the process, having already consumed whatever standard output the caller wanted.
        func finish(output data: Data = Data()) -> ProcessResult {
            process.waitUntilExit()
            errorPipe.fileHandleForReading.readabilityHandler = nil
            // Whatever landed between the last handler call and the exit.
            let remainder = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainder.isEmpty { collectedError.append(remainder) }
            return ProcessResult(
                exitCode: process.terminationStatus,
                output: data,
                errorText: collectedError.text
            )
        }
    }

    /// A lock-protected byte sink, because a `readabilityHandler` is `@Sendable` and lands on an
    /// arbitrary queue — the smallest thing that makes concurrent draining legal under Swift 6.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            data.append(chunk)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(bytes: data, encoding: .utf8) ?? ""
        }
    }
}
