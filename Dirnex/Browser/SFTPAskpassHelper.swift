import Foundation

/// Supplies the `SSH_ASKPASS` helper that lets a spawned `sftp` answer a password prompt without a
/// TTY (PLAN.md §M5 "keychain-stored password auth"). OpenSSH reads a password from the program
/// named by `SSH_ASKPASS` when `SSH_ASKPASS_REQUIRE=force` is set, so `SFTPProcessTransport` points
/// `sftp` at this script and passes the password in the child's environment.
///
/// The script on disk holds **no secret** — it just echoes an environment variable, so the password
/// only ever lives in the `sftp` process's environment (visible to same-user processes for the brief
/// life of the spawn, never written to disk). The file is written once to Application Support and
/// reused; it is regenerated automatically if missing.
enum SFTPAskpassHelper {
    /// The environment variable the helper echoes, set only in the `sftp` child's environment.
    static let passwordEnvironmentKey = "DIRNEX_SFTP_PASSWORD"

    /// A tiny POSIX-`sh` script that prints the password from `passwordEnvironmentKey`. `printf '%s'`
    /// emits the value verbatim (no shell expansion of its contents) followed by the newline `ssh`
    /// expects to terminate the passphrase.
    private static let scriptContents = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvironmentKey)\"\n"

    /// The absolute path to the ready-to-run helper, creating it (0700) if absent. Throws if the
    /// support directory or the script can't be written.
    static func scriptPath() throws -> String {
        let url = try scriptURL()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try scriptContents.write(to: url, atomically: true, encoding: .utf8)
        }
        // Always re-assert the mode: `ssh` refuses to run a non-executable askpass, and a fresh
        // atomic write can land with the umask's default permissions.
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url.path
    }

    private static func scriptURL() throws -> URL {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Dirnex", isDirectory: true)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("sftp-askpass.sh")
    }
}
