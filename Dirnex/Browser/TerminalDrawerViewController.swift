import AppKit
import DirnexCore
import SwiftTerm

/// The pane's owner (the window controller) — told when the drawer's shell walks to a new
/// directory, so the active pane can follow it there.
@MainActor
protocol TerminalDrawerDelegate: AnyObject {
    /// The shell's current directory changed (someone typed `cd`, or a script did). The window
    /// decides which pane, if any, should follow — the drawer has no idea what's on screen.
    func terminalDrawer(_ drawer: TerminalDrawerViewController, shellDidMoveTo directory: String)
    /// The shell exited (`exit`, ⌃D, a crash). The window closes the drawer; the next open
    /// spawns a fresh one.
    func terminalDrawerShellDidExit(_ drawer: TerminalDrawerViewController)
}

/// The terminal drawer: a real login shell in a real pseudo-terminal, under the two panes
/// (PLAN.md §M6 "Terminal drawer: bottom pane following active panel's cwd").
///
/// A thin client over the pass-7 core, exactly like every other pane surface: `TerminalShell`
/// decides what to exec and in which environment, `ShellWorkingDirectory` answers where the shell
/// is and whether it's safe to type at it, `ShellCommandLine` builds the `cd`, and SwiftTerm draws
/// the glass. Nothing here decides policy — this file only owns *when* to ask.
///
/// **The shell is spawned lazily**, on the drawer's first opening rather than at window load: a
/// shell is a live process with the user's dotfiles, their `PATH`, and their history, and an app
/// that starts one for every window nobody asked to open is presumptuous. Once spawned it lives
/// until it exits or the window closes — hiding the drawer keeps the session, the way every
/// terminal drawer does.
@MainActor
final class TerminalDrawerViewController: NSViewController {
    weak var delegate: TerminalDrawerDelegate?

    private let terminalView = DrawerTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 200))

    /// Whether a shell has been spawned yet — the lazy-start latch. A shell that has *exited*
    /// leaves this true until the window tears the drawer down, so a dead drawer doesn't silently
    /// respawn under the user.
    private(set) var hasStartedShell = false

    /// The last directory we saw the shell in, so an output burst that moved nothing (the common
    /// case — every keystroke echoes) reports nothing. Purely a change-detector: the kernel is the
    /// source of truth, this is only what we last told the delegate about.
    private var lastKnownShellDirectory: String?

    /// The shell's process id, or 0 before it has been spawned. `ShellWorkingDirectory` asks the
    /// kernel about exactly this pid.
    private var shellPID: pid_t { terminalView.process.shellPid }

    /// The pseudo-terminal's primary descriptor — what `isAtPrompt` runs `tcgetpgrp` on.
    private var terminalDescriptor: Int32 { terminalView.process.childfd }

    /// Which shell is running, so the `cd` is quoted the way *this* shell parses it (`fish` quotes
    /// unlike everything else — the reason `ShellKind` exists).
    private var shellKind: ShellKind = .other

    // MARK: - View

    override func loadView() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        // Terminal.app's own default face. `.monospacedSystemFont` would be SF Mono, which is a
        // fine font and the wrong one: this is the surface where the user's own terminal habits
        // live, so it should look like the terminal they already have.
        if let menlo = NSFont(name: "Menlo", size: 12) { terminalView.font = menlo }
        // Follow the system's text colours (and therefore Dark Mode) rather than SwiftTerm's
        // built-in black-on-white, so the drawer belongs to the window it's docked in.
        terminalView.configureNativeColors()
        terminalView.onOutput = { [weak self] in self?.checkShellDirectory() }
        terminalView.processDelegate = self

        let container = TerminalContainerView()
        container.terminalView = terminalView
        container.addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: container.topAnchor),
            terminalView.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Self.terminalLeadingPadding
            ),
            terminalView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        view = container
        // Small enough that dragging the divider down leaves a usable strip, big enough that the
        // shell never starts in a window it can't draw a prompt in.
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
    }

    /// The gap between the drawer's left edge and the shell's first column.
    ///
    /// SwiftTerm draws column zero flush against its own bounds and offers no padding of its own,
    /// so the view is inset and `TerminalContainerView` paints what's left. Left edge only: the
    /// right is where the scroller lives, and the top and bottom are where the dividers already
    /// separate the drawer from what it's docked between.
    private static let terminalLeadingPadding: CGFloat = 6

    // MARK: - The shell

    /// Spawn the login shell, in `directory` if it's a real place on disk. Does nothing once a
    /// shell has been started — reopening the drawer returns to the session you left.
    ///
    /// Starting the shell *in* the pane's directory is what makes opening the drawer type nothing:
    /// `cd` is only ever written to follow a move the user makes later, so the shell's history and
    /// its scrollback both open clean.
    func startShellIfNeeded(in directory: VFSPath?) {
        guard !hasStartedShell else { return }
        hasStartedShell = true

        let environment = ProcessInfo.processInfo.environment
        // `$SHELL` is asked, never assumed — this account may well run `/bin/bash`, and the
        // `/bin/zsh` default is only the fallback for when it says nothing usable.
        let shell = TerminalShell.login(shellPath: environment["SHELL"])
        shellKind = shell.kind
        let childEnvironment = shell.environment(
            inheriting: environment,
            appVersion: Self.appVersion,
            localeIdentifier: Self.localeIdentifier
        )
        let startDirectory = directory.flatMap { $0.backend == .local ? $0.path : nil }
        lastKnownShellDirectory = startDirectory
        terminalView.startProcess(
            executable: shell.executablePath,
            args: shell.arguments,
            // SwiftTerm wants the environment as `KEY=VALUE` lines, not a dictionary.
            environment: childEnvironment.map { "\($0.key)=\($0.value)" },
            // The leading dash — the whole login-shell mechanism, and why `~/.zprofile` (where a
            // stock Mac keeps Homebrew's `shellenv`) runs at all. See `TerminalShell.execName`.
            execName: shell.execName,
            currentDirectory: startDirectory
        )
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalView)
    }

    /// Drop the finished session so the next open spawns a fresh shell in a clean screen.
    ///
    /// Called by the window once the shell has exited. Resetting the emulator matters as much as
    /// clearing the latch: without it the new shell would draw its first prompt underneath the
    /// dead one's scrollback, and the drawer would read as a session that never ended.
    func prepareForRespawn() {
        guard hasStartedShell else { return }
        hasStartedShell = false
        lastKnownShellDirectory = nil
        terminalView.getTerminal().resetToInitialState()
    }

    /// Whether the drawer's terminal currently holds keyboard focus. The window asks before
    /// stealing a keystroke the shell should have had.
    var isTerminalFocused: Bool {
        guard let responder = view.window?.firstResponder else { return false }
        return responder === terminalView || (responder as? NSView)?.isDescendant(of: terminalView) == true
    }

    /// Kill the shell. Called when the window closes — a drawer that outlived its window would
    /// leave an orphaned shell holding the user's directory open.
    func terminateShell() {
        guard hasStartedShell, shellPID > 0 else { return }
        terminalView.terminate()
    }

    // MARK: - Following the panel

    /// Type the `cd` that moves the shell to `paneDirectory`, if it needs one and it's safe to
    /// type at all.
    ///
    /// Two gates, both from the core and both load-bearing:
    /// - `isAtPrompt` asks the pseudo-terminal whether our keystrokes would even reach the shell.
    ///   While `vim` (or `less`, or an `ssh` session) is in the foreground the answer is no, and a
    ///   `cd` typed into it would be somebody else's keystrokes — so the drawer simply stays put.
    ///   The panel and the shell disagree until the user comes back to a prompt, which is the
    ///   honest outcome: the alternative is typing into their editor.
    /// - `command(toFollow:)` returns `nil` when the shell is already there, so navigating away
    ///   and back — or opening the drawer at all — writes nothing and leaves the history clean.
    func followPanel(to paneDirectory: VFSPath) {
        guard hasStartedShell, shellPID > 0, terminalView.process.running else { return }
        guard ShellWorkingDirectory.isAtPrompt(
            shellPID: shellPID,
            terminalDescriptor: terminalDescriptor
        ) else { return }
        let shellDirectory = ShellWorkingDirectory.current(ofProcess: shellPID)
        guard let command = ShellWorkingDirectory.command(
            toFollow: paneDirectory,
            shellDirectory: shellDirectory,
            kind: shellKind,
            resolve: Self.resolve
        ) else { return }
        // Remember where we just sent it *before* the echo arrives, so the shell's own reply to
        // our command doesn't read as the user moving and bounce back at the panel.
        lastKnownShellDirectory = Self.resolve(paneDirectory.path)
        terminalView.send(txt: command)
    }

    /// The shell's current directory, straight from the kernel, or `nil` before it's running.
    var shellDirectory: String? {
        guard hasStartedShell, shellPID > 0 else { return nil }
        return ShellWorkingDirectory.current(ofProcess: shellPID)
    }

    /// Ask the kernel where the shell is, and tell the delegate when that has changed.
    ///
    /// Called on **every chunk of output the shell produces** — no timer, and no polling of an
    /// idle app: a shell that says nothing is asked nothing. That is affordable only because
    /// `proc_pidinfo` was measured at 0.75 µs (pass 7), which is cheaper than the memcpy of the
    /// bytes that triggered it; the expensive half — navigating a pane — is gated behind an
    /// actual change, and a `cd` is rare while echoed keystrokes are not.
    private func checkShellDirectory() {
        guard shellPID > 0, let directory = ShellWorkingDirectory.current(ofProcess: shellPID) else {
            return
        }
        let resolved = Self.resolve(directory)
        guard resolved != lastKnownShellDirectory else { return }
        lastKnownShellDirectory = resolved
        delegate?.terminalDrawer(self, shellDidMoveTo: directory)
    }

    /// The resolver the core's policy is injected with. **It must be applied to both sides of
    /// every comparison**: Foundation normalizes the `/tmp` pair by *stripping* `/private`
    /// (`/private/tmp/x` and `/tmp/x` both come back as `/tmp/x`), so it agrees with the kernel's
    /// fully-resolved answer only when the panel's path goes through it too. Feeding it one side
    /// and a raw kernel path the other reports a difference that doesn't exist — the bug pass 7's
    /// own harness wrote, and the reason this is one function rather than two call sites.
    private static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The app's version, handed to the child as `TERM_PROGRAM_VERSION` beside
    /// `TERM_PROGRAM=Dirnex`.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A POSIX locale name for the `LANG` the core supplies when the app was launched without one —
    /// which a GUI app always is.
    ///
    /// Built from the language and region rather than handed `Locale.current.identifier`, because
    /// that can carry modern suffixes (`en_US@rg=gbzzzz`) no `setlocale` has heard of — and then
    /// run past the core's policy, which drops it for neutral UTF-8 unless this system really has
    /// it. That check is not hypothetical: this very account is `en_UA`, which macOS offers and
    /// ships no locale for. See `TerminalShell.usableLocaleIdentifier`.
    private static var localeIdentifier: String? {
        let preferred: String?
        if let language = Locale.current.language.languageCode?.identifier,
           let region = Locale.current.region?.identifier {
            preferred = "\(language)_\(region)"
        } else {
            preferred = nil
        }
        return TerminalShell.usableLocaleIdentifier(
            preferred: preferred,
            isLocaleAvailable: localeExists
        )
    }

    /// Whether `name` is a locale this system can actually load — `newlocale(3)`, which asks the
    /// same database the child's `setlocale` will, without disturbing our own locale the way
    /// `setlocale` would (it is process-global, and we are a GUI app with threads).
    private static func localeExists(_ name: String) -> Bool {
        guard let locale = newlocale(LC_CTYPE_MASK, name, nil) else { return false }
        freelocale(locale)
        return true
    }
}

// MARK: - LocalProcessTerminalViewDelegate

/// `@preconcurrency` because SwiftTerm is a Swift 5 module: its delegate protocol carries no
/// isolation, so a `@MainActor` conformance needs the annotation, which turns the guarantee into a
/// runtime assertion. That assertion is safe here, and it was *checked* rather than hoped for:
/// every delivery path in `LocalProcess` runs on the queue the view constructs it with, which
/// `LocalProcessTerminalView` leaves nil and the library documents (and `usesMainQueue`
/// implements) as `DispatchQueue.main` — `dataReceived` via `drainReceivedData`, and
/// `processTerminated` via a `DispatchSource` process monitor built on that same queue. The one
/// call site that would have fired from the background read queue is commented out in the library.
extension TerminalDrawerViewController: @preconcurrency LocalProcessTerminalViewDelegate {
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        delegate?.terminalDrawerShellDidExit(self)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    /// OSC 7 — the escape sequence a shell *can* use to announce its directory, and the one the
    /// plan expected us to depend on. Deliberately ignored: these are bytes written by whatever is
    /// running in the terminal, so an `ssh` host or a `cat` of a crafted file could push a path of
    /// its choosing at the panel. The kernel can't be talked into lying about our own child's cwd,
    /// so `checkShellDirectory` asks it instead (see `ShellWorkingDirectory`).
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// The drawer's container, which exists to paint the padding strip beside the terminal.
///
/// It asks the terminal for its background rather than holding a colour of its own, because the
/// strip has to be indistinguishable from the console it is part of — and the console's background
/// moves: `configureNativeColors` follows the system's `textBackgroundColor` (so, Dark Mode), and a
/// program can repaint it out from under us with OSC 11. `nativeBackgroundColor` is where SwiftTerm
/// tracks both; a colour copied once here would be right until the first time either happened.
private final class TerminalContainerView: NSView {
    weak var terminalView: DrawerTerminalView?

    override func draw(_ dirtyRect: NSRect) {
        (terminalView?.nativeBackgroundColor ?? .textBackgroundColor).setFill()
        dirtyRect.fill()
    }

    /// A dynamic `NSColor` resolves against the appearance in force when it's *drawn*, so following
    /// a Dark Mode switch means asking to be drawn again — nothing else invalidates us.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// The terminal view itself, subclassed for one reason: to notice that the shell said something.
///
/// `dataReceived` is SwiftTerm's own delivery of the child's bytes to the emulator, which makes it
/// the exact moment worth asking the kernel where the shell now is — the shell only ever answers a
/// `cd` by drawing a new prompt, and it can't have moved without saying *something*. Probed rather
/// than assumed: `LocalProcessTerminalView` builds its `LocalProcess` with a nil queue, which the
/// library documents (and its `usesMainQueue` implements) as `DispatchQueue.main`, so this arrives
/// on the main actor like every other UI event.
private final class DrawerTerminalView: LocalProcessTerminalView {
    /// Called after each chunk of the child's output has been fed to the emulator.
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }
}
