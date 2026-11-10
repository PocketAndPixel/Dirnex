import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What Open in Terminal runs, against a **real `sshd`** with a real terminal attached (PLAN.md §M38
/// Slice 3).
///
/// Live because the question is what a real `ssh` makes of the script: that it signs in with what
/// came through the pipe, that the server's own shell lands in the folder, and that a wrong secret
/// ends where a person can read why. `script(1)` supplies the terminal, so the run needs no window.
///
/// Gated on the config files the other SFTP suites use, so CI skips it. The throwaway `sshd` takes
/// keys only, so the pipe is exercised through a key's passphrase, which reaches `ssh` the same way
/// a password does. **`SFTPLivePasswordEnvironment` runs the password route itself**, when a real
/// password account has been configured.
///
/// **Read the run's issue count, not the per-test ticks** (▸ ``offCooperativePool``).
@Suite("Open in Terminal ▸ live ssh", .enabled(if: SFTPLiveEnvironment.current != nil))
struct SSHTerminalLiveTests {
    private static let closePrompt = "Press Return to close."

    private func session(
        _ location: SFTPLocation,
        _ authentication: SFTPAuthentication,
        in directory: String
    ) -> SSHTerminalSession {
        SSHTerminalSession(
            location: location,
            dial: .asTyped(location.host),
            authentication: authentication,
            directory: directory,
            connectTimeout: 15
        )
    }

    /// A folder on the server, whose name a shell would make something of if it were not quoted.
    private func hostileFolder(_ config: SFTPLiveEnvironment.Config) throws -> String {
        let path = config.remotePath + "/it's a $dir-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// A copy of the suite's key that opens only with `passphrase`. The same public key, so the
    /// throwaway server already trusts it.
    private func encryptedKey(_ config: SFTPLiveEnvironment.Config, passphrase: String) throws -> String {
        let directory = NSTemporaryDirectory() + "dirnex-terminal-key-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let copy = directory + "/id"
        try FileManager.default.copyItem(atPath: config.identityFile, toPath: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-p", "-q", "-f", copy, "-P", "", "-N", passphrase]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return copy
    }

    /// Run the stage's script in a real terminal, typing one line at the server's shell.
    ///
    /// The line is typed ahead, which is also what answers the pause after a failure. Stdin stays
    /// open until the script is done, since `script(1)` ends the session at its end-of-file. No
    /// agent in the environment, so a key can only be opened by what came through the pipe.
    private func runInTerminal(_ stage: SSHTerminalStage) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", stage.scriptPath]
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TERM": "xterm"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data("printf 'LANDED:%s:END\\n' \"$PWD\"; exit\n".utf8))
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        input.fileHandleForWriting.closeFile()
        return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
    }

    private struct Outcome {
        let status: Int32
        let output: String
        /// Whether the stage saw its script run, or its secret read.
        let taken: Bool
    }

    private func run(_ stage: SSHTerminalStage) async throws -> Outcome {
        async let taken = BlockingWork.run { stage.finish() }
        let result = try await offCooperativePool { try runInTerminal(stage) }
        return await Outcome(status: result.status, output: result.output, taken: taken)
    }

    @Test("a key account lands in a folder with a hostile name, on the server's own shell")
    func keyAccountLands() async throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let folder = try hostileFolder(config)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let stage = try SSHTerminalStage(
            session: session(config.location, .key(identityFile: config.identityFile), in: folder),
            secret: nil,
            closePrompt: Self.closePrompt
        )

        let result = try await run(stage)

        #expect(result.status == 0)
        #expect(result.output.contains("LANDED:\(folder):END"))
        #expect(result.taken)
        #expect(!FileManager.default.fileExists(atPath: stage.scriptPath))
    }

    @Test("a secret through the pipe signs in, and nothing of it is left on disk")
    func secretThroughThePipe() async throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let passphrase = "s3cret $ 'phrase'"
        let key = try encryptedKey(config, passphrase: passphrase)
        defer { try? FileManager.default.removeItem(
            atPath: (key as NSString).deletingLastPathComponent
        ) }
        let folder = try hostileFolder(config)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let stage = try SSHTerminalStage(
            session: session(config.location, .key(identityFile: key), in: folder),
            secret: passphrase,
            closePrompt: Self.closePrompt
        )
        let script = try Data(contentsOf: URL(fileURLWithPath: stage.scriptPath))
        #expect(script.range(of: Data(passphrase.utf8)) == nil)

        let result = try await run(stage)

        #expect(result.status == 0)
        #expect(result.output.contains("LANDED:\(folder):END"))
        #expect(result.taken)
        #expect(
            !FileManager.default.fileExists(
                atPath: (stage.scriptPath as NSString).deletingLastPathComponent
            )
        )
    }

    @Test("a wrong secret ends on ssh's own words, and waits to be read")
    func wrongSecretEndsReadably() async throws {
        let config = try #require(SFTPLiveEnvironment.current)
        let key = try encryptedKey(config, passphrase: "the right one")
        defer { try? FileManager.default.removeItem(
            atPath: (key as NSString).deletingLastPathComponent
        ) }
        let stage = try SSHTerminalStage(
            session: session(config.location, .key(identityFile: key), in: config.remotePath),
            secret: "not the right one",
            closePrompt: Self.closePrompt
        )

        let result = try await run(stage)

        #expect(result.status == 255)
        #expect(result.output.contains("Permission denied"))
        #expect(result.output.contains(Self.closePrompt))
        // With the slash, because the terminal echoes the typed line, whose text says `LANDED:%s`.
        #expect(!result.output.contains("LANDED:/"))
    }

    @Test(
        "a password account signs in with the password from the pipe",
        .enabled(if: SFTPLivePasswordEnvironment.current != nil)
    )
    func passwordAccount() async throws {
        let config = try #require(SFTPLivePasswordEnvironment.current)
        let stage = try SSHTerminalStage(
            session: session(config.location, .password, in: "/"),
            secret: config.password,
            closePrompt: Self.closePrompt
        )

        let result = try await run(stage)

        #expect(result.status != 255)
        #expect(result.taken)
    }
}
