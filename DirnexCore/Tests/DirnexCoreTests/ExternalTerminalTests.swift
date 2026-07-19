import Foundation
import Testing

@testable import DirnexCore

@Suite("ExternalTerminal")
struct ExternalTerminalTests {
    /// A probe reporting the given paths as present.
    private func probe(installed: Set<String>) -> (String) -> Bool {
        { installed.contains($0) }
    }

    @Test("an app bundle is opened through open(1) with the directory as an argument")
    func bundleInvocation() {
        let invocation = ExternalTerminal.terminal.invocation(
            openingDirectory: "/Users/me/src",
            pathExists: probe(installed: ["/System/Applications/Utilities/Terminal.app"])
        )
        #expect(invocation?.executablePath == "/usr/bin/open")
        #expect(invocation?.arguments == [
            "-a", "/System/Applications/Utilities/Terminal.app", "/Users/me/src"
        ])
    }

    @Test("a CLI terminal takes the directory after its leading arguments")
    func executableInvocation() {
        let invocation = ExternalTerminal.wezTerm.invocation(
            openingDirectory: "/Users/me/src",
            pathExists: probe(installed: ["/opt/homebrew/bin/wezterm"])
        )
        #expect(invocation?.executablePath == "/opt/homebrew/bin/wezterm")
        #expect(invocation?.arguments == ["start", "--cwd", "/Users/me/src"])
    }

    @Test("the directory is an argument, so a hostile name needs no quoting and gets none")
    func directoryIsNotShellText() {
        // Nothing here reaches a shell's parser: open(1) and wezterm receive argv, not a command
        // line — which is why this path has no ShellQuoting in it at all.
        let hostile = #"/tmp/it's a "test" $(touch /tmp/pwned); rm -rf x"#
        let invocation = ExternalTerminal.terminal.invocation(
            openingDirectory: hostile,
            pathExists: probe(installed: ["/System/Applications/Utilities/Terminal.app"])
        )
        #expect(invocation?.arguments.last == hostile)
    }

    @Test("a terminal that is not installed yields no invocation")
    func uninstalledIsNil() {
        #expect(
            ExternalTerminal.iTerm.invocation(
                openingDirectory: "/tmp",
                pathExists: probe(installed: [])
            ) == nil
        )
    }

    @Test("installedPath picks the first candidate in preference order")
    func installedPathPrefersFirst() {
        // WezTerm's in-bundle CLI comes before Homebrew's shim so an app-only install works.
        let path = ExternalTerminal.wezTerm.installedPath(
            where: probe(installed: [
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "/opt/homebrew/bin/wezterm"
            ])
        )
        #expect(path == "/Applications/WezTerm.app/Contents/MacOS/wezterm")
    }

    @Test("installed reports only what is there, in preference order")
    func installedFiltersAndOrders() {
        let installed = ExternalTerminal.installed(
            where: probe(installed: [
                "/System/Applications/Utilities/Terminal.app",
                "/Applications/iTerm.app"
            ])
        )
        #expect(installed.map(\.identifier) == ["iterm", "terminal"])
    }

    @Test("preferred honours the user's choice when it is installed, else falls back")
    func preferredHonoursChoice() {
        let all = probe(installed: [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app"
        ])
        #expect(
            ExternalTerminal.preferred(identifier: "terminal", where: all)?.identifier == "terminal"
        )
        // An uninstalled preference falls back rather than failing: the user may have removed it.
        #expect(ExternalTerminal.preferred(identifier: "wezterm", where: all)?.identifier == "iterm")
        #expect(ExternalTerminal.preferred(where: all)?.identifier == "iterm")
    }

    @Test("Terminal.app is the always-available fallback, as it ships with macOS")
    func terminalIsAlwaysAvailable() {
        let onlyStock = probe(installed: ["/System/Applications/Utilities/Terminal.app"])
        #expect(ExternalTerminal.preferred(where: onlyStock)?.identifier == "terminal")
        #expect(ExternalTerminal.preferred(where: probe(installed: [])) == nil)
    }
}
