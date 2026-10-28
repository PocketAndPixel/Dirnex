import Foundation

/// Asking the user's own shell for the `PATH` their terminal has, once per user-script run.
///
/// ``ToolSearchPath`` covers what macOS itself registers, and it cannot see what the user's shell
/// startup files add. rustup puts `~/.cargo/bin` there, the python.org installer its framework
/// directory, and nvm, pyenv, conda and `brew shellenv` all work the same way. Reading those files
/// means running them, so the app starts the shell once as a login, interactive shell, which is
/// what Terminal.app starts, and has it write `PATH` to a file. The app half, with the timeout, is
/// `LoginShellPathReader`; this is the command, its environment and the parse.
///
/// - **Login and interactive both**, so `~/.zprofile` and `~/.zshrc` (or `~/.bash_profile`) run as
///   they do in Terminal. Measured 2026-10-21: `bash -l -i -c` read a fixture `~/.bash_profile` and
///   `zsh -l -i -c` a fixture `~/.zshrc`, and neither rewrote the history file. tcsh refuses `-l`
///   beside other flags, and so falls back.
/// - **The answer goes to a file, not to stdout.** A startup file can print anything, so stdout
///   would need parsing around the noise. It can also leave a background job holding stdout open,
///   and then a pipe read waits for that job rather than for the shell. stdout and stderr go to
///   `/dev/null`, and the file is only read once the shell has exited.
/// - **The terminal identity is the drawer's**, from ``TerminalShell``'s `environment(inheriting:…)`.
///   Launched from Terminal.app, the app carries `TERM_PROGRAM=Apple_Terminal` and a
///   `TERM_SESSION_ID`, and handed those, an interactive zsh wrote `~/.zsh_sessions/<id>.session`
///   and `.history` (measured). The probe would be making Terminal.app session files.
public enum ShellPathProbe {
    /// The variable naming the file the shell writes its `PATH` to. A variable rather than text in
    /// the command, so the path needs no quoting in any shell's syntax.
    public static let outputFileVariable = "DIRNEX_SHELL_PATH_FILE"

    /// The shell's arguments: login, interactive, and one command. `printenv` is named by absolute
    /// path, since the `PATH` it prints is the one being asked about.
    public static let arguments = [
        "-l", "-i", "-c", "/usr/bin/printenv PATH > \"$\(outputFileVariable)\""
    ]

    /// The probe shell's environment: `base` with the drawer's terminal identity, plus the output
    /// file's variable.
    public static func environment(
        inheriting base: [String: String],
        shell: String,
        outputFile: String,
        appVersion: String
    ) -> [String: String] {
        var environment = TerminalShell(executablePath: shell)
            .environment(inheriting: base, appVersion: appVersion)
        environment[outputFileVariable] = outputFile
        return environment
    }

    /// The directories in what the shell wrote, in order, with a repeat dropped and each entry
    /// through the same rule as a `paths` file (``ToolSearchPath``): a leading `~` expanded against
    /// `home`, and a relative or empty entry skipped. `nil` when nothing usable is left, which the
    /// caller reads as no answer.
    public static func directories(fromOutput text: String, home: String) -> [String]? {
        let value = text.hasSuffix("\n") ? String(text.dropLast()) : text
        var directories: [String] = []
        for entry in value.split(separator: ":") {
            guard let directory = ToolSearchPath.absoluteDirectory(String(entry), home: home),
                  !directories.contains(directory) else { continue }
            directories.append(directory)
        }
        return directories.isEmpty ? nil : directories
    }
}
