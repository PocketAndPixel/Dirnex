import Darwin
import Foundation

/// Keeping a terminal drawer and its panel pointed at the same directory (PLAN.md §M6 "bottom pane
/// following active panel's cwd; 'cd sync back' via shell integration snippet").
///
/// **There is no snippet, and there should not be one.** The plan assumed the drawer would learn
/// the shell's directory the way terminal emulators traditionally do: have the user install a hook
/// into their `~/.zshrc` that prints an escape sequence (OSC 7, `\e]7;file://host/path\a`) at every
/// prompt, then parse it out of the terminal's output. macOS ships exactly that hook — but
/// `/etc/zshrc` only sources it for `TERM_PROGRAM=Apple_Terminal` (see `TerminalShell`), so an
/// honest drawer would have to ship and install its own.
///
/// The kernel already knows. `proc_pidinfo` reports any same-user process's current directory, the
/// drawer's shell is our own child, and Dirnex is unsandboxed by design (§2) — so `cd` is visible
/// with **no dotfile edits, no snippet to install, and no cooperation from the shell at all**. It
/// works on first launch, for `fish` and `nushell` as well as `zsh`, and for a `cd` typed inside a
/// subshell or a script. Measured at **0.75 µs** per call, so it can simply be asked whenever the
/// terminal produces output. Verified against a real interactive `zsh` under a real pseudo-terminal:
/// `cd /usr/local` was visible immediately, with nothing installed anywhere.
///
/// It is also the *safer* of the two. OSC 7 is bytes written into the terminal by whatever is
/// running in it — SwiftTerm's own documentation warns the contents are "entirely under the control
/// of the remote application" — so a hostile `ssh` host, or a `cat` of a crafted file, could push a
/// path of its choosing at the panel. The kernel cannot be talked into lying about our child's cwd,
/// which is why nothing here parses OSC 7 even though the emulator hands it to us for free.
public enum ShellWorkingDirectory {
    /// The current directory of `pid`, or `nil` when it cannot be read — the process has exited, or
    /// belongs to another user (both verified to fail cleanly rather than hand back a stale path;
    /// `pid 1` answers `EPERM`, an exited child answers nothing).
    ///
    /// The path arrives **fully resolved**: a shell sitting in `/tmp` is reported as
    /// `/private/tmp`, because the kernel knows the vnode, not the symlink the user typed. That is
    /// the reason `directoryToFollow` and `command(toFollow:)` compare resolved paths on both sides
    /// rather than strings — see their notes.
    public static func current(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Whether `shellPID` is sitting at its prompt with nothing running in front of it.
    ///
    /// This is the gate on *writing* to the drawer, and it is what keeps Dirnex from typing a `cd`
    /// into somebody's `vim` session. A pseudo-terminal's foreground process group is what receives
    /// typed input; while the shell waits at a prompt that is the shell itself, and while a command
    /// runs it is that command. Asking `tcgetpgrp` is asking "would my keystrokes go to the shell?"
    /// — the same question, and the only one that matters here.
    public static func isAtPrompt(shellPID: pid_t, terminalDescriptor: Int32) -> Bool {
        guard shellPID > 0, terminalDescriptor >= 0 else { return false }
        return tcgetpgrp(terminalDescriptor) == shellPID
    }

    /// Where the panel should navigate to reflect a shell now sitting in `shellDirectory`, or `nil`
    /// when it is already showing it and nothing should move.
    ///
    /// `resolve` must resolve symlinks (`URL.resolvingSymlinksInPath` in the app; injected so the
    /// policy is testable without a filesystem). **Comparing raw strings here would make the panel
    /// jump**: a panel showing `/tmp` that tells its shell to `cd -- '/tmp'` gets a shell reporting
    /// `/private/tmp` back, which as a string is a different directory — so the panel would
    /// "follow" the shell to the very place it already was, moving the user's view out from under
    /// them in response to its own message.
    ///
    /// It is applied to **both** sides, which is not merely tidy — Foundation's resolver normalizes
    /// that pair by *stripping* `/private`, not by adding it (`/private/tmp/x` and `/tmp/x` both
    /// come back as `/tmp/x`), so it agrees with the kernel only when both paths go through it.
    /// Feeding it one side and the raw kernel path on the other compares `/tmp/x` against
    /// `/private/tmp/x` and reports a difference that does not exist — verified, by writing exactly
    /// that bug into this pass's own test harness.
    ///
    /// A panel that is not on the local filesystem — inside an archive, on an SFTP server — never
    /// follows: there is no shell directory that could correspond to it.
    public static func directoryToFollow(
        shellDirectory: String,
        paneDirectory: VFSPath,
        resolve: (String) -> String
    ) -> VFSPath? {
        guard paneDirectory.backend == .local else { return nil }
        guard resolve(shellDirectory) != resolve(paneDirectory.path) else { return nil }
        return .local(shellDirectory)
    }

    /// What to write into the shell to move it to `paneDirectory`, or `nil` when it is already
    /// there (or the panel has no on-disk directory to offer).
    ///
    /// Emitting nothing for a shell that is already in the right place is what keeps this feature
    /// out of the user's shell history: navigating away and back, or opening the drawer on the
    /// directory it was spawned in, produces no command at all. Only a real move types anything.
    public static func command(
        toFollow paneDirectory: VFSPath,
        shellDirectory: String?,
        kind: ShellKind,
        resolve: (String) -> String
    ) -> String? {
        guard paneDirectory.backend == .local else { return nil }
        if let shellDirectory, resolve(shellDirectory) == resolve(paneDirectory.path) { return nil }
        return ShellCommandLine.changeDirectory(to: paneDirectory.path, kind: kind)
    }
}
