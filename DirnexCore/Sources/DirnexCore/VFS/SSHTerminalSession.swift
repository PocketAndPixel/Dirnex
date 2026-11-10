import Foundation

/// An `ssh` session to an SFTP account, in the folder its pane is showing: what Open in Terminal
/// runs where a local shell cannot go (PLAN.md §M38 Slice 3).
///
/// Holds no secret, like ``SFTPLocation`` and ``SFTPAuthentication``. A password travels beside it,
/// through ``SSHTerminalStage``.
public struct SSHTerminalSession: Sendable, Hashable {
    public let location: SFTPLocation
    /// The name that resolved for this connection, which is not always the account's own.
    public let dial: DialedHost
    public let authentication: SFTPAuthentication
    /// The remote folder the session lands in.
    public let directory: String
    public let connectTimeout: Int

    public init(
        location: SFTPLocation,
        dial: DialedHost,
        authentication: SFTPAuthentication,
        directory: String,
        connectTimeout: Int
    ) {
        self.location = location
        self.dial = dial
        self.authentication = authentication
        self.directory = directory
        self.connectTimeout = connectTimeout
    }

    /// What the server's shell runs: into the folder, then the account's own shell in its place.
    ///
    /// `;` and not `&&`, so a folder that has gone since the listing still gives a shell, under the
    /// server's own `cd` error. `-l` because a command channel starts no login shell by itself, and
    /// a person expects their profile. The directory can be a name a stranger chose, so it is
    /// quoted (▸ ``SSHShellQuote``).
    var remoteCommand: String {
        "cd \(SSHShellQuote.quote(directory)); exec \"$SHELL\" -l"
    }

    /// Everything after `ssh` on its command line. Never holds a secret, since this ends up in the
    /// process list.
    var arguments: [String] {
        SFTPProcessArguments.terminal(
            location: location,
            dial: dial,
            authentication: authentication,
            connectTimeout: connectTimeout,
            command: remoteCommand
        )
    }

    /// The script a terminal runs for this session. `askpassPath` names the helper that answers a
    /// password prompt, and is `nil` for a key.
    ///
    /// Three things worth knowing about what it says:
    ///
    /// - It deletes itself first, so a terminal that keeps a window open keeps no file behind it.
    /// - `SSH_ASKPASS_REQUIRE=force` is what sends the prompt to the helper while a real terminal
    ///   is attached, where `ssh` would otherwise ask at the keyboard.
    /// - **255 is `ssh`'s own failure**, to connect or to sign in, and its message is the reason. A
    ///   terminal may close the moment the script ends (iTerm does by default), so it waits for a
    ///   Return. Any other status came from the session and needs no such pause.
    func launchScript(askpassPath: String?, closePrompt: String) -> String {
        var lines = ["#!/bin/sh", "/bin/rm -f -- \"$0\""]
        if let askpassPath {
            lines += [
                "SSH_ASKPASS=\(SSHShellQuote.quote(askpassPath))",
                "SSH_ASKPASS_REQUIRE=force",
                "export SSH_ASKPASS SSH_ASKPASS_REQUIRE"
            ]
        }
        lines += [
            ([Self.sshPath] + arguments).map(SSHShellQuote.quote).joined(separator: " "),
            "status=$?",
            "if [ \"$status\" -eq 255 ]; then printf '\\n%s ' "
                + "\(SSHShellQuote.quote(closePrompt)); read -r _; fi",
            "exit \"$status\""
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static let sshPath = "/usr/bin/ssh"
}
