import Foundation

/// Making this copy of Dirnex git's merge tool (PLAN.md §M37 Slice 6): the three values
/// `git mergetool` reads from the user's global config, what they say now, and writing or removing
/// them. Pure but for the injected `GitTransport`.
public enum GitMergeToolSetup {
    /// The name the tool goes by in git's config.
    public static let toolName = "dirnex"

    /// What the global git config says about Dirnex and `git mergetool`.
    public enum State: Sendable, Equatable {
        /// Dirnex is not the merge tool, with the name of the one that is, if any.
        case notSetUp(otherTool: String?)
        /// `git mergetool` runs this copy of Dirnex.
        case active
        /// `git mergetool` runs Dirnex through a command that is not this copy's: the app moved, or
        /// another copy set it up. Carries what the config holds.
        case otherCopy(command: String)
    }

    /// The value of `mergetool.dirnex.cmd` for the binary at `executablePath`.
    ///
    /// git runs it through `eval` in a shell, so the binary's path is quoted (a space in it is
    /// ordinary) and the four variables are left for that shell to expand. A real `git mergetool`
    /// ran a path holding a space, a quote and a dollar sign this way.
    public static func command(executablePath: String) -> String {
        let quoted = "'" + executablePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "\(quoted) \(GitMergeArguments.flag) \"$LOCAL\" \"$BASE\" \"$REMOTE\" \"$MERGED\""
    }

    /// What `mergeTool`, `command` and `trustExitCode`, as the config holds them, amount to.
    ///
    /// Only `merge.tool` naming Dirnex makes it the tool. Without `trustExitCode`, git would ask
    /// whether a merge worked rather than read the exit status, so a config lacking it is not set
    /// up, and setting up writes it.
    public static func state(
        mergeTool: String?,
        command configured: String?,
        trustExitCode: Bool,
        executablePath: String
    ) -> State {
        guard mergeTool == toolName, let configured else {
            return .notSetUp(otherTool: mergeTool == toolName ? nil : mergeTool)
        }
        guard configured == command(executablePath: executablePath) else {
            return .otherCopy(command: configured)
        }
        return trustExitCode ? .active : .notSetUp(otherTool: nil)
    }

    /// What the global config says now, for the binary at `executablePath`.
    public static func read(
        executablePath: String,
        transport: some GitTransport
    ) throws(GitRunFailure) -> State {
        let trust = try value(of: trustKey, asBool: true, transport: transport)
        return try state(
            mergeTool: value(of: toolKey, asBool: false, transport: transport),
            command: value(of: commandKey, asBool: false, transport: transport),
            trustExitCode: trust == "true",
            executablePath: executablePath
        )
    }

    /// Make the binary at `executablePath` git's merge tool. `merge.tool` goes last, so a write that
    /// fails halfway leaves `git mergetool` running whatever it ran before.
    public static func apply(
        executablePath: String,
        transport: some GitTransport
    ) throws(GitRunFailure) {
        _ = try transport.run(
            ["config", "--global", commandKey, command(executablePath: executablePath)]
        )
        _ = try transport.run(["config", "--global", trustKey, "true"])
        _ = try transport.run(["config", "--global", toolKey, toolName])
    }

    /// Take Dirnex out of the global config. `merge.tool` is removed only while it names Dirnex, and
    /// goes first, so a write that fails halfway does not leave git naming a tool it can't find.
    public static func remove(transport: some GitTransport) throws(GitRunFailure) {
        if try value(of: toolKey, asBool: false, transport: transport) == toolName {
            _ = try transport.run(["config", "--global", "--unset", toolKey])
        }
        do {
            _ = try transport.run(["config", "--global", "--remove-section", section])
        } catch where error.status == noSuchSectionStatus {
            // Already gone, which is what was asked for.
        }
    }

    private static let toolKey = "merge.tool"
    private static let section = "mergetool.\(toolName)"
    private static let commandKey = "\(section).cmd"
    private static let trustKey = "\(section).trustExitCode"
    /// `git config --get`'s status for a key that is not set (probed 2026-11-09, git 2.54).
    private static let unsetStatus: Int32 = 1
    /// `git config --remove-section`'s status for a section that is not there, and `--type=bool`'s
    /// for a value that is not one.
    private static let noSuchSectionStatus: Int32 = 128

    /// The key's value, or `nil` when it is unset or, for a boolean, not one.
    private static func value(
        of key: String,
        asBool: Bool,
        transport: some GitTransport
    ) throws(GitRunFailure) -> String? {
        let type = asBool ? ["--type=bool"] : []
        do {
            let output = try transport.run(["config", "--global"] + type + ["--get", key])
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        } catch where error.status == unsetStatus || (asBool && error.status == noSuchSectionStatus) {
            return nil
        }
    }
}
