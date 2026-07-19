import Foundation
import Testing

@testable import DirnexCore

@Suite("ShellCommandLine")
struct ShellCommandLineTests {
    /// A directory name is attacker-controlled data (unzip something from the internet and you can
    /// be browsing it), and it lands on the command line of an interactive shell. This exact name
    /// was verified against real `zsh` and `bash`: both entered the directory, neither substitution
    /// fired.
    private let hostileName = #"it's a "test" $(touch /tmp/pwned) `touch /tmp/pwned2` ;rm -rf boom; & |x"#

    @Test("POSIX quoting neutralizes every metacharacter, closing and reopening for a quote")
    func posixQuotingIsInert() {
        let quoted = ShellQuoting.quoted(hostileName, for: .zsh)
        // Single quotes have no escapes, so the only thing to handle is the quote itself.
        #expect(
            quoted == #"'it'\''s a "test" $(touch /tmp/pwned) `touch /tmp/pwned2` ;rm -rf boom; & |x'"#
        )
        // Every dangerous construct survives as literal text rather than syntax.
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
    }

    @Test("a quote is the only POSIX escape, and it does not leave the string open")
    func posixQuoteBalances() {
        // Balance check: outside the '\'' bridges, quoting must open and close cleanly.
        #expect(ShellQuoting.quoted("a'b", for: .bash) == #"'a'\''b'"#)
        #expect(ShellQuoting.quoted("plain", for: .bash) == "'plain'")
        #expect(ShellQuoting.quoted("", for: .bash) == "''")
    }

    @Test("fish escapes inside single quotes instead, where POSIX's bridge would corrupt the path")
    func fishQuotingUsesBackslashes() {
        // fish honours \ and ' escapes inside single quotes, so the POSIX '\'' would leave a stray
        // backslash in the directory name.
        #expect(ShellQuoting.quoted("a'b", for: .fish) == #"'a\'b'"#)
        #expect(ShellQuoting.quoted(#"back\slash"#, for: .fish) == #"'back\\slash'"#)
        // A dollar or backtick still needs nothing: single quotes suppress expansion in fish too.
        #expect(ShellQuoting.quoted("$(boom)", for: .fish) == "'$(boom)'")
    }

    @Test("unknown shells are quoted as POSIX")
    func otherQuotesAsPOSIX() {
        #expect(ShellQuoting.quoted("a'b", for: .other) == ShellQuoting.quoted("a'b", for: .zsh))
    }

    @Test("changeDirectory clears the line first, so a half-typed command cannot be executed")
    func changeDirectoryClearsTypedText() {
        let command = ShellCommandLine.changeDirectory(to: "/Users/me", kind: .zsh)
        // ^C is SIGINT by way of the terminal's line discipline, so the shell abandons the line
        // whatever its editor had in it.
        #expect(command.hasPrefix("\u{03}"))
        #expect(command == "\u{03} cd -- '/Users/me'\n")
    }

    /// The clear must stay *ahead* of anything we type, or it would discard our own command
    /// instead of the user's abandoned one.
    @Test("changeDirectory puts nothing at all before the clear")
    func changeDirectoryClearsBeforeTyping() {
        for kind in [ShellKind.zsh, .bash, .fish, .other] {
            let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: kind)
            #expect(command.first == "\u{03}")
            #expect(command.filter { $0 == "\u{03}" }.count == 1)
        }
    }

    /// Regression, the reason this is `^C` and not the idiomatic clear-line keys: **a keystroke is
    /// a bet on the user's keymap, and in vi mode the bet loses.** `^K`, `^A` and `^E` are all
    /// `self-insert` in both `bash`'s `vi-insert` and `zsh`'s `viins` (dumped from the real
    /// shells), so they land in the line as text — a `^K` had `bash` answering every pane switch
    /// with `$'\v': command not found` while the `cd` never arrived. `^U` is bound in `bash` but is
    /// `vi-kill-line` in `zsh`'s `viins`, which kills back only to where insert mode was entered
    /// and so clears *nothing* after `ESC` `A` — executing the user's abandoned words. Nothing we
    /// send may depend on a binding.
    @Test("changeDirectory sends no key that vi mode would type into the line instead of obeying")
    func changeDirectorySendsNoKeymapDependentKey() {
        for kind in [ShellKind.zsh, .bash, .fish, .other] {
            let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: kind)
            // ^U, ^K, ^A, ^E — every key the "obvious" clear-line sequences reach for.
            for key in ["\u{15}", "\u{0B}", "\u{01}", "\u{05}"] {
                #expect(!command.contains(key))
            }
        }
    }

    /// Regression: `bash` binds `^U` to readline's `unix-line-discard`, which rings the terminal
    /// bell instead of killing when the cursor sits at column zero — every idle prompt, which is
    /// precisely where the panel-follow `cd` is typed. SwiftTerm turns that BEL into
    /// `NSSound.beep()`, so every pane switch beeped like a rejected shortcut. `^C` retires the
    /// problem rather than tiptoeing around it: with no `^U` in the sequence there is nothing that
    /// can ring, which a pty confirms for vi *command* mode too — where the old space-plus-`^U`
    /// still beeped 5–8 times a move.
    @Test("changeDirectory sends no ^U, so bash cannot ding at an empty prompt")
    func changeDirectoryDoesNotDingBash() {
        for kind in [ShellKind.zsh, .bash, .fish, .other] {
            let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: kind)
            #expect(!command.contains("\u{15}"))
            #expect(command.hasPrefix("\u{03}"))
        }
    }

    @Test("changeDirectory offers history the leading space and ends the line")
    func changeDirectoryShape() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: .bash)
        #expect(command.contains(" cd -- "))
        #expect(command.hasSuffix("\n"))
    }

    @Test("changeDirectory ends option parsing so a directory named like a flag stays a path")
    func changeDirectoryEndsOptions() {
        #expect(
            ShellCommandLine.changeDirectory(to: "/tmp/-p", kind: .zsh).contains("cd -- '/tmp/-p'")
        )
    }

    @Test("fish gets a plain cd, whose -- handling is not the shell's to promise")
    func fishOmitsOptionTerminator() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp", kind: .fish)
        #expect(command == "\u{03} cd '/tmp'\n")
        #expect(!command.contains("--"))
    }

    @Test("a hostile directory name produces one cd command and no second command")
    func hostileNameStaysOneCommand() {
        let command = ShellCommandLine.changeDirectory(to: "/tmp/" + hostileName, kind: .zsh)
        // Exactly one line: the newline we add is the only one, so nothing can run on its own.
        #expect(command.filter { $0 == "\n" }.count == 1)
        #expect(command.hasSuffix("\n"))
    }
}
