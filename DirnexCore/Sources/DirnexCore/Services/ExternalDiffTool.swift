import Foundation

/// An external file-comparison ("diff") application Dirnex can hand two files to — the second
/// half of Compare-by-content (PLAN.md §M5). `ByteComparator` answers *whether* two files differ;
/// this answers *how*, by opening them side-by-side in FileMerge, Kaleidoscope, BBEdit, or any
/// tool that takes two file paths as arguments.
///
/// This is a pure descriptor: it knows a tool's name, where its command-line launcher might live,
/// and how to assemble the argument vector — but it launches nothing (the app spawns the resolved
/// invocation). Locating the launcher is an injected `executableExists` probe, so the whole model
/// is testable without a real Xcode/Kaleidoscope/BBEdit install (per PLAN.md §2, the logic lives
/// here and has tests; the app is a thin launcher over it).
public struct ExternalDiffTool: Sendable, Hashable, Identifiable {
    public var id: String { identifier }

    /// A stable identifier, used to persist the user's chosen tool.
    public let identifier: String
    /// The name shown in menus ("Compare with Kaleidoscope…") and settings.
    public let displayName: String
    /// Absolute paths its command-line launcher might live at, most-preferred first. The first one
    /// that exists (and is executable) is used — Homebrew installs to `/opt/homebrew/bin` on Apple
    /// Silicon or `/usr/local/bin` on Intel, while FileMerge's `opendiff` lives inside Xcode.
    public let candidateExecutablePaths: [String]
    /// Arguments placed *before* the two file paths (most tools need none; a flag goes here).
    public let leadingArguments: [String]

    public init(
        identifier: String,
        displayName: String,
        candidateExecutablePaths: [String],
        leadingArguments: [String] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.candidateExecutablePaths = candidateExecutablePaths
        self.leadingArguments = leadingArguments
    }

    /// The first candidate path `executableExists` accepts, or `nil` when the tool isn't installed.
    public func executablePath(where executableExists: (String) -> Bool) -> String? {
        candidateExecutablePaths.first(where: executableExists)
    }

    /// A concrete launch — executable plus argument vector — that compares `leftPath` against
    /// `rightPath`, or `nil` when the tool isn't installed. The two paths are passed verbatim as
    /// the final two arguments, after any `leadingArguments`.
    public func invocation(
        comparing leftPath: String,
        with rightPath: String,
        executableExists: (String) -> Bool
    ) -> ExternalDiffInvocation? {
        guard let executablePath = executablePath(where: executableExists) else { return nil }
        return ExternalDiffInvocation(
            executablePath: executablePath,
            arguments: leadingArguments + [leftPath, rightPath]
        )
    }
}

/// A resolved external-diff launch: the executable to run and the full argument vector, ready to
/// hand to a process launcher.
public struct ExternalDiffInvocation: Sendable, Hashable {
    public let executablePath: String
    public let arguments: [String]

    public init(executablePath: String, arguments: [String]) {
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public extension ExternalDiffTool {
    /// FileMerge's bundle identifier, the one LaunchServices finds it by.
    static let fileMergeBundleIdentifier = "com.apple.FileMerge"

    /// Xcode's FileMerge, launched through the `opendiff` that ships in the same Xcode
    /// (`Xcode.app/Contents/Developer/usr/bin/opendiff`, beside
    /// `Xcode.app/Contents/Applications/FileMerge.app`). `opendiff a b` opens the two files in a
    /// comparison window.
    ///
    /// **Not `/usr/bin/opendiff`** (PLAN.md §M31 Slice 4). That one is a shim present on every Mac,
    /// so finding it says nothing about FileMerge, and it runs the copy in the *active developer
    /// directory*: with the Command Line Tools selected it exits 1 with *"tool 'opendiff' requires
    /// Xcode"*. Xcode's own copy, run directly, opens FileMerge whichever directory is selected
    /// (measured 2026-10-22, docs/NOTES.md ▸ Xcode's tool shims). So FileMerge counts as installed
    /// exactly when an Xcode holding it is, and `locateBundle` (LaunchServices, in the app) is what
    /// finds that Xcode wherever it was put and whatever it is called.
    static func fileMerge(locateBundle: (String) -> String?) -> ExternalDiffTool {
        let launcher = locateBundle(fileMergeBundleIdentifier).map { fileMergePath in
            URL(fileURLWithPath: fileMergePath)
                .deletingLastPathComponent() // Contents/Applications
                .deletingLastPathComponent() // Contents
                .appendingPathComponent("Developer/usr/bin/opendiff")
                .path
        }
        return ExternalDiffTool(
            identifier: "filemerge",
            displayName: "FileMerge",
            candidateExecutablePaths: launcher.map { [$0] } ?? []
        )
    }

    /// Kaleidoscope, via the `ksdiff` command-line integration it installs.
    static let kaleidoscope = ExternalDiffTool(
        identifier: "kaleidoscope",
        displayName: "Kaleidoscope",
        candidateExecutablePaths: ["/opt/homebrew/bin/ksdiff", "/usr/local/bin/ksdiff"]
    )

    /// BBEdit, via its `bbdiff` command-line tool.
    static let bbEdit = ExternalDiffTool(
        identifier: "bbedit",
        displayName: "BBEdit",
        candidateExecutablePaths: ["/opt/homebrew/bin/bbdiff", "/usr/local/bin/bbdiff"]
    )

    /// The tools Dirnex knows how to launch, in preference order — dedicated diff apps first, then
    /// FileMerge as the ships-with-Xcode fallback. The first installed one wins when the user
    /// hasn't picked a specific tool.
    static func known(locateBundle: (String) -> String?) -> [ExternalDiffTool] {
        [.kaleidoscope, .bbEdit, .fileMerge(locateBundle: locateBundle)]
    }

    /// The known tools whose launcher is installed, in preference order.
    static func installed(
        locateBundle: (String) -> String?,
        where executableExists: (String) -> Bool
    ) -> [ExternalDiffTool] {
        known(locateBundle: locateBundle).filter { $0.executablePath(where: executableExists) != nil }
    }
}
