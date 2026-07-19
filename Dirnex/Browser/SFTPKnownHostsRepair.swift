import Foundation

/// Removes a stale host-key pin from `known_hosts` so a reconnect can trust the server's new key.
/// Spawns `ssh-keygen -R` — the supported way to delete an entry (it handles hashed hostnames and
/// writes a `.old` backup) — rather than editing the file by hand. Runs only after the user
/// explicitly confirms the change in the warning dialog; call it off the main thread.
enum SFTPKnownHostsRepair {
    /// Drop every pinned key for `target` (a bare host, or the `[host]:port` form from
    /// `SFTPKnownHosts.removalTarget`) from the `known_hosts` file. Passing the exact `knownHostsFile`
    /// OpenSSH reported keeps the removal aimed at the file it refused on; an empty path lets
    /// `ssh-keygen` use its default (`~/.ssh/known_hosts`). Returns whether `ssh-keygen` exited
    /// cleanly.
    static func removeKey(target: String, knownHostsFile: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var arguments = ["-R", target]
        if !knownHostsFile.isEmpty {
            arguments += ["-f", knownHostsFile]
        }
        process.arguments = arguments
        // Its output is a couple of status lines we don't need; discard both so nothing can fill a
        // pipe buffer, and only the exit status matters.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
