import Foundation

/// The files one Open in Terminal launch needs, in a folder of their own that no other user can
/// read, with no secret in any of them (PLAN.md §M38 Slice 3).
///
/// A terminal is handed ``scriptPath`` and runs it. Dirnex does not spawn that process, so it has no
/// way to reach its environment or its stdin, which is how a password gets to every other `ssh` it
/// runs. For a password account the script points `ssh` at a small helper that reads a
/// ``OneShotSecretPipe``, and ``finish(isCancelled:)`` is what puts the secret in the pipe.
///
/// The folder is removed by ``finish(isCancelled:)``, once the terminal has taken what it holds or
/// has plainly not come for it. The launch can wait a long time for a person: iTerm asks "OK to
/// run?" before it runs anything.
public struct SSHTerminalStage: Sendable {
    /// What to hand the terminal.
    public let scriptPath: String

    let directory: String
    let secretPipe: OneShotSecretPipe?
    private let secret: Data?
    private let patience: TimeInterval

    /// How long a launch waits for the terminal, in seconds: long enough to answer iTerm's question
    /// and for a slow server to reach its password prompt.
    public static let defaultPatience: TimeInterval = 120

    /// `secret` is the account's password, or `nil` for a key.
    public init(
        session: SSHTerminalSession,
        secret: String?,
        closePrompt: String,
        root: String = NSTemporaryDirectory(),
        patience: TimeInterval = SSHTerminalStage.defaultPatience
    ) throws {
        let fileManager = FileManager.default
        let directory = (root as NSString).appendingPathComponent("Dirnex-ssh-\(UUID().uuidString)")
        try fileManager.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.privateMode]
        )
        do {
            let askpass = secret == nil ? nil : (directory as NSString)
                .appendingPathComponent("askpass")
            let pipe = try askpass.map { try Self.placeAskpass(at: $0, in: directory) }
            let script = (directory as NSString).appendingPathComponent("session.command")
            try Self.writeExecutable(
                session.launchScript(askpassPath: askpass, closePrompt: closePrompt),
                to: script
            )
            self.directory = directory
            scriptPath = script
            secretPipe = pipe
            self.secret = secret.map { Data($0.utf8) + Data("\n".utf8) }
            self.patience = patience
        } catch {
            try? fileManager.removeItem(atPath: directory)
            throw error
        }
    }

    /// Wait for the terminal to take what this stage holds, then remove the stage. Answers whether
    /// it was taken.
    ///
    /// Blocks for up to the stage's patience, so call it off the main thread. A password is taken
    /// when the helper reads it. A key has nothing to hand over, so the sign is the script deleting
    /// itself, which is the first thing it does.
    @discardableResult
    public func finish(isCancelled: () -> Bool = { false }) -> Bool {
        defer { discard() }
        if let secretPipe, let secret {
            return secretPipe.deliver(secret, timeout: patience, isCancelled: isCancelled)
        }
        let deadline = Date().addingTimeInterval(patience)
        while access(scriptPath, F_OK) == 0 {
            guard Date() < deadline, !isCancelled() else { return false }
            usleep(Self.pollMicroseconds)
        }
        return true
    }

    /// Remove the stage now: for a terminal that could not be launched at all.
    public func discard() {
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// The helper `ssh` runs for the password: `cat` of the pipe, with the pipe beside it.
    private static func placeAskpass(
        at path: String,
        in directory: String
    ) throws -> OneShotSecretPipe {
        let pipe = try OneShotSecretPipe(
            path: (directory as NSString).appendingPathComponent("secret")
        )
        try writeExecutable("#!/bin/sh\n/bin/cat \(SSHShellQuote.quote(pipe.path))\n", to: path)
        return pipe
    }

    private static func writeExecutable(_ text: String, to path: String) throws {
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: privateMode]
        ) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static let privateMode = 0o700
    private static let pollMicroseconds: UInt32 = 50000
}
