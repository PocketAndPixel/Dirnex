import Darwin
import Foundation
import Testing

@testable import DirnexCore

@Suite("ShellWorkingDirectory")
struct ShellWorkingDirectoryTests {
    /// The one symlink every Mac has, and the exact shape that would make a panel jump: the kernel
    /// reports a shell in `/tmp` as being in `/private/tmp`.
    private func resolve(_ path: String) -> String {
        path.hasPrefix("/tmp") ? "/private" + path : path
    }

    @Test("the kernel reports our own current directory, with no cooperation from anyone")
    func readsOwnWorkingDirectory() {
        // Hermetic: our own process is a same-user process like the drawer's shell would be, so
        // this exercises the real syscall without spawning anything.
        let reported = ShellWorkingDirectory.current(ofProcess: getpid())
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        #expect(reported == expected)
    }

    @Test("an unreadable process answers nil rather than a stale or wrong path")
    func unreadableProcessIsNil() {
        // pid 1 is launchd, running as root: a different user, so proc_pidinfo refuses (verified:
        // EPERM). Silence is the only safe answer — a wrong path here navigates the user's panel.
        #expect(ShellWorkingDirectory.current(ofProcess: 1) == nil)
        #expect(ShellWorkingDirectory.current(ofProcess: 0) == nil)
        #expect(ShellWorkingDirectory.current(ofProcess: -1) == nil)
    }

    @Test("the panel follows the shell into a directory it is not already showing")
    func paneFollowsShell() {
        let followed = ShellWorkingDirectory.directoryToFollow(
            shellDirectory: "/Users/me/src",
            paneDirectory: .local("/Users/me"),
            resolve: resolve
        )
        #expect(followed == .local("/Users/me/src"))
    }

    @Test("the panel does not follow a shell that is already where it is")
    func paneStaysPut() {
        let followed = ShellWorkingDirectory.directoryToFollow(
            shellDirectory: "/Users/me",
            paneDirectory: .local("/Users/me"),
            resolve: resolve
        )
        #expect(followed == nil)
    }

    @Test("a panel showing /tmp does not jump to /private/tmp when its own cd echoes back")
    func symlinkedDirectoryDoesNotPingPong() {
        // The panel tells its shell to cd -- '/tmp'; the kernel then reports /private/tmp. Compared
        // as strings that is a different directory, so the panel would "follow" the shell to the
        // place it already was — moving the view in response to its own message.
        let followed = ShellWorkingDirectory.directoryToFollow(
            shellDirectory: "/private/tmp",
            paneDirectory: .local("/tmp"),
            resolve: resolve
        )
        #expect(followed == nil)
    }

    @Test("a panel that is not on disk never follows a shell")
    func virtualPaneNeverFollows() {
        // Inside an archive or on SFTP there is no shell directory that could correspond.
        let inArchive = VFSPath(backend: .archive(forArchiveAt: "/Users/me/pkg.zip"), path: "/src")
        #expect(
            ShellWorkingDirectory.directoryToFollow(
                shellDirectory: "/Users/me",
                paneDirectory: inArchive,
                resolve: resolve
            ) == nil
        )
        let results = VFSPath(backend: .search, path: "/results")
        #expect(
            ShellWorkingDirectory.directoryToFollow(
                shellDirectory: "/Users/me",
                paneDirectory: results,
                resolve: resolve
            ) == nil
        )
    }

    @Test("the shell is told to follow the panel when it is somewhere else")
    func shellFollowsPane() {
        let command = ShellWorkingDirectory.command(
            toFollow: .local("/Users/me/src"),
            shellDirectory: "/Users/me",
            kind: .zsh,
            resolve: resolve
        )
        #expect(command == "\u{03} cd -- '/Users/me/src'\n")
    }

    @Test("a shell already in the right place is told nothing, which is what keeps history clean")
    func shellAlreadyThereIsSilent() {
        #expect(
            ShellWorkingDirectory.command(
                toFollow: .local("/Users/me"),
                shellDirectory: "/Users/me",
                kind: .zsh,
                resolve: resolve
            ) == nil
        )
        // Including through the symlink: opening the drawer on /tmp must not type a cd.
        #expect(
            ShellWorkingDirectory.command(
                toFollow: .local("/tmp"),
                shellDirectory: "/private/tmp",
                kind: .zsh,
                resolve: resolve
            ) == nil
        )
    }

    @Test("a shell whose directory is unknown is told where to go")
    func unknownShellDirectoryStillFollows() {
        let command = ShellWorkingDirectory.command(
            toFollow: .local("/Users/me"),
            shellDirectory: nil,
            kind: .bash,
            resolve: resolve
        )
        #expect(command == "\u{03} cd -- '/Users/me'\n")
    }

    @Test("a panel that is not on disk asks the shell for nothing")
    func virtualPaneSendsNothing() {
        let inArchive = VFSPath(backend: .archive(forArchiveAt: "/Users/me/pkg.zip"), path: "/src")
        #expect(
            ShellWorkingDirectory.command(
                toFollow: inArchive,
                shellDirectory: "/Users/me",
                kind: .zsh,
                resolve: resolve
            ) == nil
        )
    }

    @Test("a closed or invalid terminal is never at a prompt")
    func invalidTerminalIsNotAtPrompt() {
        // The gate on writing: without a real pty, tcgetpgrp cannot say the shell would receive our
        // keystrokes, so the answer must be no.
        #expect(!ShellWorkingDirectory.isAtPrompt(shellPID: 42, terminalDescriptor: -1))
        #expect(!ShellWorkingDirectory.isAtPrompt(shellPID: 0, terminalDescriptor: 0))
    }
}
