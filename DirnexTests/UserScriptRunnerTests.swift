import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-side runner that spawns a `UserScript` (PLAN.md §M6 "user actions — shell scripts
/// receiving selection as argv/env"). `DirnexCore.UserScript` is unit-tested for the argv/env it
/// *builds*; these tests spawn real `/bin/sh` processes to prove the runner honours that contract
/// end-to-end — the working directory, the merged `DIRNEX_*` environment, the per-file fan-out,
/// exit-code/stderr reporting, and — the load-bearing one — that an attacker-controlled filename
/// rides in `argv` as inert data and cannot execute.
@MainActor
@Suite("UserScriptRunner")
struct UserScriptRunnerTests {
    /// Run `script` in `directory` against `selection`, awaiting the outcome. `/bin/sh` is the
    /// shell so the tests don't depend on the host's login shell.
    private func run(
        _ script: UserScript,
        in directory: URL,
        selection: [URL],
        otherDirectory: String? = nil
    ) async -> UserScriptRunner.RunOutcome {
        let context = UserScriptContext(
            selection: selection.map(\.path),
            currentDirectory: directory.path,
            otherDirectory: otherDirectory
        )
        return await withCheckedContinuation { continuation in
            UserScriptRunner.run(script, context: context, shell: "/bin/sh") { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// A throwaway directory holding `files` (each created empty), cleaned up by the caller.
    private func makeFixture(files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dirnex-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path,
                contents: nil
            )
        }
        return dir
    }

    @Test("a combined run sees the selection as arguments and the DIRNEX_* environment")
    func combinedRunPassesArgvAndEnvironment() async throws {
        let dir = try makeFixture(files: ["a.txt", "b.txt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = ["a.txt", "b.txt"].map { dir.appendingPathComponent($0) }

        let script = UserScript(
            name: "Dump",
            command: """
            printf '%s\\n' "$@" > out.txt
            printf 'count=%s\\n' "$DIRNEX_SELECTION_COUNT" >> out.txt
            printf 'cur=%s\\n' "$DIRNEX_CURRENT_DIR" >> out.txt
            printf 'other=%s\\n' "$DIRNEX_OTHER_DIR" >> out.txt
            """,
            runMode: .combined
        )
        let outcome = await run(script, in: dir, selection: files, otherDirectory: "/tmp/other")

        #expect(outcome.total == 1)
        #expect(outcome.failures.isEmpty)
        // `out.txt` is written relative to the process cwd, proving `currentDirectoryPath` took.
        let output = try String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(output == """
        \(files[0].path)
        \(files[1].path)
        count=2
        cur=\(dir.path)
        other=/tmp/other

        """)
    }

    @Test("a per-file run launches once per selected file")
    func perFileRunLaunchesPerFile() async throws {
        let dir = try makeFixture(files: ["one", "two", "three"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = ["one", "two", "three"].map { dir.appendingPathComponent($0) }

        let script = UserScript(name: "Mark", command: #": > "$1.done""#, runMode: .perFile)
        let outcome = await run(script, in: dir, selection: files)

        #expect(outcome.total == 3)
        #expect(outcome.failures.isEmpty)
        for file in files {
            #expect(FileManager.default.fileExists(atPath: file.path + ".done"))
        }
    }

    @Test("a per-file run over an empty selection launches nothing")
    func perFileRunWithNoSelectionDoesNothing() async throws {
        let dir = try makeFixture(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = UserScript(name: "Mark", command: #": > "$1.done""#, runMode: .perFile)
        let outcome = await run(script, in: dir, selection: [])

        #expect(outcome.total == 0)
        #expect(outcome.failures.isEmpty)
    }

    @Test("a non-zero exit is reported with its status and stderr")
    func nonZeroExitIsReported() async throws {
        let dir = try makeFixture(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = UserScript(name: "Fail", command: "echo boom >&2; exit 3", runMode: .combined)
        let outcome = await run(script, in: dir, selection: [])

        #expect(outcome.total == 1)
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.exitCode == 3)
        #expect(outcome.failures.first?.stderr == "boom")
    }

    @Test("an attacker-controlled filename rides in argv as inert data and cannot execute")
    func hostileFilenameDoesNotExecute() async throws {
        let dir = try makeFixture(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        // A file whose *name* is a command substitution: unzipping a download can put exactly this
        // in front of you. It must reach the script as one literal `"$1"`, never be evaluated.
        let hostileName = "$(touch pwned.txt)"
        let hostile = dir.appendingPathComponent(hostileName)
        FileManager.default.createFile(atPath: hostile.path, contents: nil)

        // The body echoes its first positional argument verbatim into `captured.txt`.
        let script = UserScript(
            name: "Echo",
            command: #"printf '%s' "$1" > captured.txt"#,
            runMode: .combined
        )
        let outcome = await run(script, in: dir, selection: [hostile])

        #expect(outcome.failures.isEmpty)
        // The substitution never ran: no `pwned.txt` was created anywhere it could reach.
        #expect(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("pwned.txt").path)
        )
        // And the argument arrived byte-for-byte as the hostile path.
        let captured = try String(
            contentsOf: dir.appendingPathComponent("captured.txt"),
            encoding: .utf8
        )
        #expect(captured == hostile.path)
    }
}
