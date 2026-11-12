import Foundation

/// What `Dirnex --git-merge` asks of the running app (PLAN.md §M37 Slice 6): the four files
/// `git mergetool` names, each as an absolute path, so what the app reads does not depend on where
/// the command was run.
public struct GitMergeRequest: Codable, Sendable, Equatable {
    /// `$LOCAL`: a temporary copy of yours, which git removes once the command exits.
    public let local: String
    /// `$BASE`: a temporary copy of the common ancestor, empty when both sides added the file.
    public let base: String
    /// `$REMOTE`: a temporary copy of theirs.
    public let remote: String
    /// `$MERGED`: the working-tree file, holding git's conflict markers, and the one file a save
    /// writes.
    public let merged: String

    public init(local: String, base: String, remote: String, merged: String) {
        self.local = local
        self.base = base
        self.remote = remote
        self.merged = merged
    }

    /// The name of the file being merged.
    public var name: String {
        VFSPath.local(merged).lastComponent
    }
}

/// How one merge ended, as the app tells the command.
public struct GitMergeAnswer: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable {
        /// The window saved a result into `$MERGED` before it closed.
        case saved
        /// The window closed with nothing saved.
        case notSaved
        /// The window did not open, for the reason in `message`.
        case refused
    }

    public let outcome: Outcome
    /// Why a merge was refused, in the app's language, for the command's standard error.
    public let message: String?

    public init(outcome: Outcome, message: String? = nil) {
        self.outcome = outcome
        self.message = message
    }

    public static let saved = GitMergeAnswer(outcome: .saved)
    public static let notSaved = GitMergeAnswer(outcome: .notSaved)

    public static func refused(_ message: String) -> GitMergeAnswer {
        GitMergeAnswer(outcome: .refused, message: message)
    }

    /// What the command exits with. Under `trustExitCode` git stages the file on 0 and reports
    /// the merge as failed on anything else, so only a saved result may answer 0.
    public var exitCode: Int32 {
        outcome == .saved ? 0 : 1
    }
}

/// Reading the command line of `Dirnex --git-merge` (PLAN.md §M37 Slice 6).
public enum GitMergeArguments {
    /// The flag that makes the binary a command instead of the app.
    public static let flag = "--git-merge"

    /// What the command prints when it is called wrongly.
    public static let usage = "usage: Dirnex \(flag) LOCAL BASE REMOTE MERGED"

    /// Whether `arguments`, as `CommandLine.arguments` holds them, ask for the command.
    ///
    /// Only the first argument counts. A normal launch has none, or the `-AppleLanguages` kind a
    /// test or Xcode adds, and a file named `--git-merge` further along is not a request.
    public static func isInvocation(_ arguments: [String]) -> Bool {
        arguments.count > 1 && arguments[1] == flag
    }

    /// The request `arguments` make, or `nil` when they are not exactly the four paths.
    ///
    /// `git mergetool` passes relative paths with the command's working directory at the top of
    /// the worktree (`./a_LOCAL_74127.txt`, `sub/a.txt`), and the app has a working directory of
    /// its own, so each is made absolute here. Nothing is read: a dash at the start of a name
    /// stays part of the name, since these positions are always paths.
    public static func request(from arguments: [String], currentDirectory: String) -> GitMergeRequest? {
        guard isInvocation(arguments), arguments.count == 6 else { return nil }
        let paths = arguments[2...].compactMap { absolute($0, in: currentDirectory) }
        guard paths.count == 4 else { return nil }
        return GitMergeRequest(local: paths[0], base: paths[1], remote: paths[2], merged: paths[3])
    }

    /// `path` as an absolute path, or `nil` when it is empty or has nothing to be relative to.
    ///
    /// Each `.` component is dropped, and a `..` is left for the file system, since only it knows
    /// what a symbolic link before it points at (`VFSPath`'s own rule).
    private static func absolute(_ path: String, in directory: String) -> String? {
        guard !path.isEmpty, path.hasPrefix("/") || directory.hasPrefix("/") else { return nil }
        let joined = path.hasPrefix("/") ? path : directory + "/" + path
        let kept = joined.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return VFSPath.local(kept.joined(separator: "/")).path
    }
}
