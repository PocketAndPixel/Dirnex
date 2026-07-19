import Foundation
import Testing

@testable import DirnexCore

@Suite("TerminalShell")
struct TerminalShellTests {
    @Test("the shell kind is the executable's basename")
    func kindFromPath() {
        #expect(ShellKind(executablePath: "/bin/zsh") == .zsh)
        #expect(ShellKind(executablePath: "/bin/bash") == .bash)
        #expect(ShellKind(executablePath: "/opt/homebrew/bin/fish") == .fish)
        #expect(ShellKind(executablePath: "/usr/local/bin/nu") == .other)
        #expect(ShellKind(executablePath: "/bin/ksh") == .other)
    }

    @Test("login uses $SHELL when it is an absolute path")
    func loginUsesUserShell() {
        // The account this was written on runs /bin/bash, which is exactly why $SHELL is asked
        // rather than assumed: a pre-Catalina account never moved to zsh.
        #expect(TerminalShell.login(shellPath: "/bin/bash").executablePath == "/bin/bash")
        #expect(TerminalShell.login(shellPath: "/bin/bash").kind == .bash)
    }

    @Test("login falls back to the macOS default when $SHELL says nothing usable")
    func loginFallsBack() {
        #expect(TerminalShell.login(shellPath: nil).executablePath == "/bin/zsh")
        #expect(TerminalShell.login(shellPath: "").executablePath == "/bin/zsh")
        // A relative value is not a shell we can exec; it is something's idea of a joke.
        #expect(TerminalShell.login(shellPath: "zsh").executablePath == "/bin/zsh")
    }

    @Test("argv[0] carries the login dash, which is what makes the drawer inherit the user's PATH")
    func execNameIsLoginShell() {
        #expect(TerminalShell(executablePath: "/bin/zsh").execName == "-zsh")
        #expect(TerminalShell(executablePath: "/opt/homebrew/bin/fish").execName == "-fish")
        // The dash asks for login and the pty makes it interactive, so no -l/-i is needed.
        #expect(TerminalShell(executablePath: "/bin/zsh").arguments.isEmpty)
    }

    @Test("we name ourselves Dirnex, which is what stops zsh sourcing Apple's Terminal dotfile")
    func terminalProgramIsDirnex() {
        let environment = TerminalShell(executablePath: "/bin/zsh")
            .environment(inheriting: [:], appVersion: "1.2.3")
        // /etc/zshrc sources /etc/zshrc_$TERM_PROGRAM. Claiming Apple_Terminal would take over the
        // user's ~/.zsh_sessions bookkeeping and split their history; /etc/zshrc_Dirnex does not
        // exist, so nothing extra is sourced.
        #expect(environment["TERM_PROGRAM"] == "Dirnex")
        #expect(environment["TERM_PROGRAM_VERSION"] == "1.2.3")
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["COLORTERM"] == "truecolor")
    }

    @Test("the launching terminal's identity is stripped, never handed to our child")
    func inheritedTerminalIdentityIsStripped() {
        // Dirnex launched from a terminal (open, xcodebuild, a shell) inherits all of this.
        let base = [
            "TERM_PROGRAM": "Apple_Terminal",
            "TERM_SESSION_ID": "w0t0p0:ABC-123",
            "ITERM_SESSION_ID": "w0t1p0",
            "ITERM_PROFILE": "Default",
            "LC_TERMINAL": "iTerm2",
            "LC_TERMINAL_VERSION": "3.5.0",
            "PATH": "/usr/bin",
            "HOME": "/Users/me"
        ]
        let environment = TerminalShell(executablePath: "/bin/zsh")
            .environment(inheriting: base, appVersion: "1.0")
        #expect(environment["TERM_SESSION_ID"] == nil)
        #expect(environment["ITERM_SESSION_ID"] == nil)
        #expect(environment["ITERM_PROFILE"] == nil)
        #expect(environment["LC_TERMINAL"] == nil)
        #expect(environment["LC_TERMINAL_VERSION"] == nil)
        #expect(environment["TERM_PROGRAM"] == "Dirnex")
        // The rest of the environment is the user's and is passed through untouched.
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["HOME"] == "/Users/me")
    }

    @Test("LANG is supplied only when the app was given none")
    func localeFillsOnlyWhenMissing() {
        let shell = TerminalShell(executablePath: "/bin/zsh")
        // A GUI process inherits no LANG, and without one the shell's tools mangle non-ASCII names.
        let filled = shell.environment(inheriting: [:], appVersion: "1.0", localeIdentifier: "en_US")
        #expect(filled["LANG"] == "en_US.UTF-8")
        let empty = shell.environment(
            inheriting: ["LANG": ""],
            appVersion: "1.0",
            localeIdentifier: "en_US"
        )
        #expect(empty["LANG"] == "en_US.UTF-8")
        // The user's own choice always wins.
        let existing = shell.environment(
            inheriting: ["LANG": "de_DE.UTF-8"],
            appVersion: "1.0",
            localeIdentifier: "en_US"
        )
        #expect(existing["LANG"] == "de_DE.UTF-8")
        // And with no locale to offer we invent nothing.
        #expect(shell.environment(inheriting: [:], appVersion: "1.0")["LANG"] == nil)
    }

    /// The system this was written on reports `en_UA` — English, in Ukraine — a language/region
    /// pair macOS lets you pick and then ships no locale for. The drawer's first live run greeted
    /// it with `perl: warning: Setting locale failed.`, which is the bug this policy exists for.
    @Test("a locale the system doesn't have falls back to neutral UTF-8, not a warning")
    func unavailableLocaleFallsBackToNeutral() {
        // A stock Mac's locale list: en_US and friends, uk_UA — but no en_UA.
        let available: Set<String> = ["en_US.UTF-8", "uk_UA.UTF-8", "de_DE.UTF-8", "C.UTF-8"]
        let probe: (String) -> Bool = { available.contains($0) }

        #expect(
            TerminalShell.usableLocaleIdentifier(preferred: "en_UA", isLocaleAvailable: probe) == "C"
        )
        #expect(
            TerminalShell.usableLocaleIdentifier(preferred: "en_US", isLocaleAvailable: probe) == "en_US"
        )
        #expect(
            TerminalShell.usableLocaleIdentifier(preferred: nil, isLocaleAvailable: probe) == "C"
        )
    }

    @Test("with no usable locale at all we invent nothing rather than guess a region")
    func noUsableLocaleYieldsNothing() {
        #expect(
            TerminalShell.usableLocaleIdentifier(
                preferred: "en_UA",
                isLocaleAvailable: { _ in false }
            ) == nil
        )
    }

    /// The whole point of `LANG` is the codeset: the fallback must still be UTF-8, or the shell's
    /// tools drop to C's ASCII and mangle every non-ASCII filename — the thing this is here to stop.
    @Test("the neutral fallback composes into a UTF-8 LANG")
    func neutralFallbackIsUTF8() {
        let shell = TerminalShell(executablePath: "/bin/zsh")
        let identifier = TerminalShell.usableLocaleIdentifier(
            preferred: "en_UA",
            isLocaleAvailable: { $0 == "C.UTF-8" }
        )
        let environment = shell.environment(
            inheriting: [:],
            appVersion: "1.0",
            localeIdentifier: identifier
        )
        #expect(environment["LANG"] == "C.UTF-8")
    }
}
