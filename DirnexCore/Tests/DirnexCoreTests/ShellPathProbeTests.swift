import Foundation
import Testing

@testable import DirnexCore

@Suite("ShellPathProbe")
struct ShellPathProbeTests {
    private let home = "/Users/someone"

    @Test("the shell runs as a login, interactive shell and writes PATH to the named file")
    func arguments() {
        #expect(ShellPathProbe.arguments == [
            "-l", "-i", "-c", #"/usr/bin/printenv PATH > "$DIRNEX_SHELL_PATH_FILE""#
        ])
    }

    @Test("the probe carries the drawer's terminal identity, not the one that launched the app")
    func environmentStripsTheLaunchingTerminal() {
        let environment = ShellPathProbe.environment(
            inheriting: [
                "HOME": home,
                "PATH": "/usr/bin:/bin",
                "TERM_PROGRAM": "Apple_Terminal",
                "TERM_SESSION_ID": "w0t0p0:1234"
            ],
            shell: "/bin/zsh",
            outputFile: "/tmp/answer",
            appVersion: "1.2"
        )
        #expect(environment["TERM_PROGRAM"] == "Dirnex")
        #expect(environment["TERM_SESSION_ID"] == nil)
        #expect(environment["DIRNEX_SHELL_PATH_FILE"] == "/tmp/answer")
        #expect(environment["HOME"] == home)
        #expect(environment["PATH"] == "/usr/bin:/bin")
    }

    @Test("the answer keeps its order, drops repeats, expands a tilde and skips relative entries")
    func parsesTheAnswer() {
        let text = "/Users/someone/.cargo/bin:/usr/local/bin::.:bin:~/.local/bin:/usr/bin:/usr/local/bin\n"
        #expect(ShellPathProbe.directories(fromOutput: text, home: home) == [
            "/Users/someone/.cargo/bin", "/usr/local/bin", "/Users/someone/.local/bin", "/usr/bin"
        ])
    }

    @Test("a directory with spaces in its name is kept whole")
    func keepsSpaces() {
        let text = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin:/usr/bin\n"
        #expect(ShellPathProbe.directories(fromOutput: text, home: home) == [
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin", "/usr/bin"
        ])
    }

    @Test("an empty or unusable answer is no answer")
    func emptyAnswerIsNil() {
        #expect(ShellPathProbe.directories(fromOutput: "", home: home) == nil)
        #expect(ShellPathProbe.directories(fromOutput: "\n", home: home) == nil)
        #expect(ShellPathProbe.directories(fromOutput: "bin:.:\n", home: home) == nil)
    }
}
