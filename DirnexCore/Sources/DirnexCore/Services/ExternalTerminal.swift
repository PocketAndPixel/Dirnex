import Foundation

/// A terminal application Dirnex can open at a directory — the "open in iTerm/Terminal/WezTerm as
/// alternative" half of PLAN.md §M6's terminal item, for people who want their own terminal, with
/// their own tabs and profile, rather than the built-in drawer.
///
/// A pure descriptor, launching nothing, with the filesystem reduced to an injected `pathExists`
/// probe — `ExternalDiffTool`'s shape exactly, and for the same reason: the whole model is testable
/// without installing iTerm or WezTerm, and a tool that isn't installed is simply absent from the
/// menu rather than an error when clicked.
public struct ExternalTerminal: Sendable, Hashable, Identifiable {
    public var id: String { identifier }

    /// How this terminal is asked to open a directory. The two shapes are genuinely different
    /// programs, not a style choice: a Mac app is a bundle that `open` hands a folder to, while a
    /// cross-platform terminal ships a CLI that takes a flag.
    public enum Launch: Sendable, Hashable {
        /// An app bundle, opened as `/usr/bin/open -a <bundle> <directory>`. macOS app bundles are
        /// registered as folder handlers, and both Terminal and iTerm respond by opening a new
        /// window already `cd`'d there — so no shell command is typed and no quoting is involved.
        case applicationBundle(candidatePaths: [String])
        /// A command-line launcher taking the directory as its final argument, after
        /// `leadingArguments` (`wezterm start --cwd <dir>`).
        case executable(candidatePaths: [String], leadingArguments: [String])
    }

    /// A stable identifier, for persisting the user's chosen terminal.
    public let identifier: String
    /// The name shown in menus ("Open in WezTerm").
    public let displayName: String
    public let launch: Launch

    public init(identifier: String, displayName: String, launch: Launch) {
        self.identifier = identifier
        self.displayName = displayName
        self.launch = launch
    }

    /// The first candidate path `pathExists` accepts, or `nil` when this terminal isn't installed.
    public func installedPath(where pathExists: (String) -> Bool) -> String? {
        switch launch {
        case let .applicationBundle(candidatePaths):
            return candidatePaths.first(where: pathExists)
        case let .executable(candidatePaths, _):
            return candidatePaths.first(where: pathExists)
        }
    }

    /// A concrete launch that opens `directoryPath`, or `nil` when the terminal isn't installed.
    /// The directory is passed as an argument, never as shell text, so it needs no quoting.
    public func invocation(
        openingDirectory directoryPath: String,
        pathExists: (String) -> Bool
    ) -> ExternalTerminalInvocation? {
        guard let installedPath = installedPath(where: pathExists) else { return nil }
        switch launch {
        case .applicationBundle:
            return ExternalTerminalInvocation(
                executablePath: Self.openExecutablePath,
                arguments: ["-a", installedPath, directoryPath]
            )
        case let .executable(_, leadingArguments):
            return ExternalTerminalInvocation(
                executablePath: installedPath,
                arguments: leadingArguments + [directoryPath]
            )
        }
    }

    /// `open(1)`, which is how a bundle gets launched with an argument.
    static let openExecutablePath = "/usr/bin/open"
}

/// A resolved external-terminal launch: the executable and its full argument vector.
public struct ExternalTerminalInvocation: Sendable, Hashable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public extension ExternalTerminal {
    /// Terminal.app. Always installed — it ships with macOS — which makes it the fallback that is
    /// always available, the role `FileMerge` plays for diffing.
    static let terminal = ExternalTerminal(
        identifier: "terminal",
        displayName: "Terminal",
        launch: .applicationBundle(candidatePaths: ["/System/Applications/Utilities/Terminal.app"])
    )

    /// iTerm2.
    static let iTerm = ExternalTerminal(
        identifier: "iterm",
        displayName: "iTerm",
        launch: .applicationBundle(candidatePaths: [
            "/Applications/iTerm.app",
            "/Applications/iTerm2.app"
        ])
    )

    /// WezTerm, via the CLI in its bundle or on `PATH`. `start --cwd <dir>` opens a new window
    /// there; the in-bundle path comes first so an app-bundle install works without Homebrew's
    /// shim.
    static let wezTerm = ExternalTerminal(
        identifier: "wezterm",
        displayName: "WezTerm",
        launch: .executable(
            candidatePaths: [
                "/Applications/WezTerm.app/Contents/MacOS/wezterm",
                "/opt/homebrew/bin/wezterm",
                "/usr/local/bin/wezterm"
            ],
            leadingArguments: ["start", "--cwd"]
        )
    )

    /// The terminals Dirnex knows how to open, in preference order: the user's own choices first,
    /// then the one macOS guarantees.
    static let known: [ExternalTerminal] = [.iTerm, .wezTerm, .terminal]

    /// The known terminals that are installed, in preference order.
    static func installed(where pathExists: (String) -> Bool) -> [ExternalTerminal] {
        known.filter { $0.installedPath(where: pathExists) != nil }
    }

    /// The terminal to reach for: the one with `preferredIdentifier` when set *and* installed,
    /// otherwise the first installed one — in practice Terminal.app at worst.
    static func preferred(
        identifier preferredIdentifier: String? = nil,
        where pathExists: (String) -> Bool
    ) -> ExternalTerminal? {
        let installed = installed(where: pathExists)
        if let preferredIdentifier,
           let match = installed.first(where: { $0.identifier == preferredIdentifier }) {
            return match
        }
        return installed.first
    }
}
