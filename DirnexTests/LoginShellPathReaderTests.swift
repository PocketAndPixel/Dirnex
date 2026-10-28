import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-side reader that asks the user's shell for its `PATH` (`DirnexCore.ShellPathProbe`).
/// Each test runs a real shell with a throwaway `HOME`, so the startup file under test is the only
/// one of the user's that runs.
@Suite("LoginShellPathReader")
struct LoginShellPathReaderTests {
    /// A throwaway `HOME` holding `files` (name → contents), cleaned up by the caller.
    private func makeHome(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-shell-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for (name, text) in files {
            try Data(text.utf8).write(to: home.appendingPathComponent(name))
        }
        return home
    }

    private func read(
        shell: String = "/bin/bash",
        home: URL,
        extra: [String: String] = [:],
        timeout: DispatchTimeInterval = LoginShellPathReader.timeout
    ) -> [String]? {
        LoginShellPathReader.directories(
            shell: shell,
            environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                .merging(extra) { $1 },
            workingDirectory: home.path,
            timeout: timeout
        )
    }

    @Test("answers the PATH the startup file sets, whatever else the file prints or leaves running")
    func answersThroughNoise() throws {
        // Noise on both streams, one line shaped like a PATH, and a background job that would hold
        // a stdout pipe open for five seconds.
        let home = try makeHome([".bash_profile": """
        echo "Welcome back"
        echo "not:a:path" >&2
        (sleep 5) &
        PATH="$HOME/tools:$PATH"

        """])
        defer { try? FileManager.default.removeItem(at: home) }

        let start = ContinuousClock.now
        let directories = read(home: home)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(directories?.first == home.appendingPathComponent("tools").path)
        #expect(directories?.contains("/usr/bin") == true)
    }

    @Test(
        "a startup file that does not finish in time is killed with all it started, and there is no answer"
    )
    func hangingStartupFileTimesOut() async throws {
        // Ignoring SIGTERM defeats `terminate()`, and the subshell outlives a kill of the shell's
        // pid alone, touching `survivor` three seconds in. Only killing the group passes both.
        let home = try makeHome([".bash_profile": """
        trap '' TERM
        touch "$HOME/started"
        ( sleep 3; touch "$HOME/survivor" )

        """])
        defer { try? FileManager.default.removeItem(at: home) }

        let start = ContinuousClock.now
        let directories = read(home: home, timeout: .seconds(1))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(directories == nil)
        // Without this the run proves nothing: the shell was killed after the subshell started.
        try #require(
            FileManager.default.fileExists(atPath: home.appendingPathComponent("started").path)
        )
        try await Task.sleep(for: .milliseconds(2500))
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent("survivor").path
        ))
    }

    @Test("a startup file that exits before the command leaves no answer")
    func earlyExitIsNoAnswer() throws {
        let home = try makeHome([".bash_profile": "exit 3\n"])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(read(home: home) == nil)
    }

    @Test("a shell that cannot be launched leaves no answer")
    func missingShellIsNoAnswer() throws {
        let home = try makeHome([:])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(read(shell: "/nonexistent/shell", home: home) == nil)
    }

    @Test("launched from Terminal.app, the probe still writes no Terminal.app session files")
    func leavesTerminalSessionsAlone() throws {
        let home = try makeHome([:])
        defer { try? FileManager.default.removeItem(at: home) }

        // `/etc/zshrc_Apple_Terminal` creates `~/.zsh_sessions/<id>.session` for an interactive
        // zsh that carries Terminal.app's identity.
        let directories = read(
            shell: "/bin/zsh",
            home: home,
            extra: ["TERM_PROGRAM": "Apple_Terminal", "TERM_SESSION_ID": "dirnex-probe"]
        )
        #expect(directories?.contains("/usr/bin") == true)
        #expect(!FileManager.default.fileExists(
            atPath: home.appendingPathComponent(".zsh_sessions").path
        ))
    }
}
