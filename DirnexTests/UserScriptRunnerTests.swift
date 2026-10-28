import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// The app-side runner that spawns a `UserScript` (PLAN.md §M6 "user actions — shell scripts
/// receiving selection as argv/env"). `DirnexCore.UserScript` is unit-tested for the argv/env it
/// *builds*; these tests spawn real `/bin/sh` processes to prove the runner honors that contract
/// end-to-end — the working directory, the merged `DIRNEX_*` environment, the per-file fan-out,
/// exit-code/stderr reporting, and — the load-bearing one — that an attacker-controlled filename
/// rides in `argv` as inert data and cannot execute.
@MainActor
@Suite("UserScriptRunner")
struct UserScriptRunnerTests {
    /// Run `script` in `directory` against `selection`, awaiting the outcome. `/bin/sh` is the
    /// shell so the tests don't depend on the host's login shell, and `directory` is `HOME`, so the
    /// login shell the runner asks for its `PATH` reads no startup file of the developer's.
    private func run(
        _ script: UserScript,
        in directory: URL,
        selection: [URL],
        otherDirectory: String? = nil,
        shell: String = "/bin/sh",
        systemPaths: URL = ToolSearchPath.systemRoot
    ) async -> UserScriptRunner.RunOutcome {
        let context = UserScriptContext(
            selection: selection.map(\.path),
            currentDirectory: directory.path,
            otherDirectory: otherDirectory
        )
        return await withCheckedContinuation { continuation in
            UserScriptRunner.run(
                script,
                context: context,
                shell: shell,
                inherited: ["HOME": directory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                systemPaths: systemPaths
            ) { outcome in
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

    @Test("a tool in a folder that paths.d names runs by name")
    func toolNamedByPathsDirectoryResolves() async throws {
        let dir = try makeFixture(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        // A stand-in `/etc` whose `paths.d` names one folder, holding the only copy of the tool.
        // This is how the .NET SDK registers `dotnet`.
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        let etc = dir.appendingPathComponent("etc", isDirectory: true)
        let pathsDirectory = etc.appendingPathComponent("paths.d", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: pathsDirectory,
            withIntermediateDirectories: true
        )
        let tool = tools.appendingPathComponent("dirnex-probe-tool")
        try Data("#!/bin/sh\necho resolved > \"$1\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try Data("\(tools.path)\n".utf8).write(to: pathsDirectory.appendingPathComponent("probe"))

        let script = UserScript(name: "Probe", command: "dirnex-probe-tool out.txt")
        let outcome = await run(script, in: dir, selection: [], systemPaths: etc)

        #expect(outcome.failures.isEmpty)
        let output = try String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(output == "resolved\n")
    }

    @Test("the login shell's PATH comes first, so its copy of a tool wins")
    func toolOnTheLoginShellPathResolvesFirst() async throws {
        let dir = try makeFixture(files: [])
        defer { try? FileManager.default.removeItem(at: dir) }
        // Two tools of one name: one where `~/.bash_profile` puts it, as rustup's line does, and a
        // decoy in a folder `paths.d` names, which the runner also adds.
        let shellTools = dir.appendingPathComponent("shell-tools", isDirectory: true)
        let systemTools = dir.appendingPathComponent("system-tools", isDirectory: true)
        let etc = dir.appendingPathComponent("etc", isDirectory: true)
        let pathsDirectory = etc.appendingPathComponent("paths.d", isDirectory: true)
        for folder in [shellTools, systemTools, pathsDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for (folder, answer) in [(shellTools, "shell"), (systemTools, "system")] {
            let tool = folder.appendingPathComponent("dirnex-probe-tool")
            try Data("#!/bin/sh\necho \(answer) > \"$1\"\n".utf8).write(to: tool)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tool.path
            )
        }
        try Data("\(systemTools.path)\n".utf8)
            .write(to: pathsDirectory.appendingPathComponent("probe"))
        try Data("PATH=\"$HOME/shell-tools:$PATH\"\n".utf8)
            .write(to: dir.appendingPathComponent(".bash_profile"))

        let script = UserScript(name: "Probe", command: "dirnex-probe-tool out.txt")
        let outcome = await run(script, in: dir, selection: [], shell: "/bin/bash", systemPaths: etc)

        #expect(outcome.failures.isEmpty)
        let output = try String(contentsOf: dir.appendingPathComponent("out.txt"), encoding: .utf8)
        #expect(output == "shell\n")
    }
}
