import Foundation

/// How the core runs `git`: the app spawns the process, and a test answers from a script
/// (PLAN.md §2, subprocess I/O in the app and its parse in the core).
public protocol GitTransport: Sendable {
    /// What git printed on its standard output for `arguments`. Throws when it could not be
    /// started or exited with an error.
    func run(_ arguments: [String]) throws(GitRunFailure) -> Data
}

/// A git run that did not answer.
public struct GitRunFailure: Error, Sendable, Equatable {
    /// git's exit status, or `nil` when it could not be started.
    public let status: Int32?
    /// What git printed on its standard error, trimmed. git's own words, untranslated.
    public let message: String

    public init(status: Int32?, message: String) {
        self.status = status
        self.message = message
    }
}

/// The three versions of a conflicted file, as a checkout would write each, and what git is in
/// the middle of (PLAN.md §M34 Slice 5).
public struct GitConflictVersions: Sendable, Equatable {
    public let operation: GitOperation
    /// `nil` when both sides added the file (`AA`): the merge starts from an empty base.
    public let base: Data?
    public let ours: Data
    public let theirs: Data

    public init(operation: GitOperation, base: Data?, ours: Data, theirs: Data) {
        self.operation = operation
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }
}

/// Reading a conflicted file's versions out of git, for the merge window (PLAN.md §M34 Slice 5).
///
/// One `ls-files` lists the versions git holds and their sizes, and decides whether there is a
/// merge to make at all, before a byte is read. A `rev-parse` then names the git directory, whose
/// markers say what is in progress, and one `cat-file` per version reads its bytes. Each run is a
/// read (`GitCommand`), so git stays as the user left it: the U badge stays until they stage the
/// saved file themselves.
public enum GitConflictReader {
    /// Why the versions were not read.
    public enum Failure: Error, Sendable, Equatable {
        /// There is no one file to merge.
        case refused(GitConflictRefusal)
        /// A version is larger than the window reads. Nothing was read.
        case tooLarge(byteSize: Int64)
        /// git did not answer.
        case gitFailed(GitRunFailure)
    }

    /// The versions git holds of `relativePath`, a file in the working tree at `repositoryRoot`.
    ///
    /// A version over `byteLimit` as git stores it refuses the read. A filter can make the bytes a
    /// checkout writes a little longer, such as CRLF line endings. `exists` checks a name in the git
    /// directory, as ``GitOperation/inProgress(gitDirectory:exists:)`` asks. Blocking; call it off
    /// the main thread.
    public static func read(
        _ relativePath: String,
        inRepositoryAt repositoryRoot: String,
        byteLimit: Int64,
        transport: some GitTransport,
        exists: (String) -> Bool
    ) throws(Failure) -> GitConflictVersions {
        let listing = try run(
            GitCommand.unmergedStages(repositoryRoot: repositoryRoot, relativePath: relativePath),
            on: transport
        )
        // A literal path lists only itself, unless it names a folder. Compared as `String`s, which
        // are equal under canonical equivalence: git prints a name precomposed and a macOS path may
        // spell it decomposed (`GitStatusSnapshot`'s note on Unicode).
        let stages: GitConflictStages
        do {
            stages = try GitConflictStages.choose(
                from: GitStage.parse(listing).filter { $0.path == relativePath }
            )
        } catch {
            throw .refused(error)
        }
        let versions = [stages.base, stages.ours, stages.theirs].compactMap(\.self)
        if let large = versions.first(where: { $0.byteSize > byteLimit }) {
            throw .tooLarge(byteSize: large.byteSize)
        }
        let operation = operationInProgress(at: repositoryRoot, transport: transport, exists: exists)
        func contents(_ stage: GitStage) throws(Failure) -> Data {
            try run(
                GitCommand.stageContents(
                    repositoryRoot: repositoryRoot,
                    relativePath: stage.path,
                    object: stage.object
                ),
                on: transport
            )
        }
        var base: Data?
        if let stage = stages.base { base = try contents(stage) }
        return try GitConflictVersions(
            operation: operation,
            base: base,
            ours: contents(stages.ours),
            theirs: contents(stages.theirs)
        )
    }

    /// What is in progress, or `.other` when the git directory could not be had: it only words the
    /// panes, and the versions are what a merge needs.
    private static func operationInProgress(
        at repositoryRoot: String,
        transport: some GitTransport,
        exists: (String) -> Bool
    ) -> GitOperation {
        let arguments = GitCommand.gitDirectory(repositoryRoot: repositoryRoot)
        guard let output = try? transport.run(arguments) else { return .other }
        // swiftlint:disable:next optional_data_string_conversion
        let directory = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard directory.hasPrefix("/") else { return .other }
        return GitOperation.inProgress(gitDirectory: directory, exists: exists)
    }

    private static func run(_ arguments: [String], on transport: some GitTransport) throws(Failure) -> Data {
        do {
            return try transport.run(arguments)
        } catch {
            throw .gitFailed(error)
        }
    }
}
