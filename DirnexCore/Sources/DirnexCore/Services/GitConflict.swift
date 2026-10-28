import Foundation

/// One version git holds of a conflicted path: a record of `git ls-files --unmerged`
/// (PLAN.md §M34 Slice 5).
///
/// git keeps up to three versions in the index while a path is conflicted, each a *stage*: 1 is
/// the common ancestor, 2 is ours (`HEAD`) and 3 is theirs. Which of them exist says what kind of
/// conflict it is, which `GitConflictStages` reads.
public struct GitStage: Sendable, Hashable {
    /// 1, 2 or 3.
    public let number: Int
    /// git's mode: `100644` or `100755` for a file, `120000` for a symbolic link, `160000` for a
    /// submodule.
    public let mode: String
    /// The blob's object name.
    public let object: String
    /// The blob's size as git stores it, before any filter a checkout runs.
    public let byteSize: Int64
    /// Relative to the repository root, as git printed it.
    public let path: String

    public init(number: Int, mode: String, object: String, byteSize: Int64, path: String) {
        self.number = number
        self.mode = mode
        self.object = object
        self.byteSize = byteSize
        self.path = path
    }

    /// Whether this version is a file's bytes, rather than a link's target or a submodule's commit.
    public var isFile: Bool {
        mode == "100644" || mode == "100755"
    }

    /// The `--format` `GitCommand.unmergedStages` asks for: the mode, object, stage and size, a tab,
    /// then the path. The tab is the one separator a path cannot hide behind, since everything
    /// before it is fixed-width or a number.
    public static let listingFormat = "%(objectmode) %(objectname) %(stage) %(objectsize)%x09%(path)"

    /// The records of a `-z` listing in `listingFormat`. A record that does not read is skipped:
    /// a version missing from the list is refused by name rather than merged.
    public static func parse(_ listing: Data) -> [GitStage] {
        listing.split(separator: 0).compactMap { record in
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                  let header = String(bytes: record[..<tab], encoding: .utf8) else { return nil }
            let fields = header.split(separator: " ")
            guard fields.count == 4,
                  let number = Int(fields[2]), (1...3).contains(number),
                  let byteSize = Int64(fields[3]) else { return nil }
            // Lossy, as `GitStatusParser`'s: a name that is not UTF-8 reads as no row's path, so
            // the listing for it is empty and the file is refused as not conflicted.
            // swiftlint:disable:next optional_data_string_conversion
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            return GitStage(
                number: number,
                mode: String(fields[0]),
                object: String(fields[1]),
                byteSize: byteSize,
                path: path
            )
        }
    }
}

/// Why a conflicted path has no one file to merge, named by which of its versions git holds.
public enum GitConflictRefusal: Error, Sendable, Equatable {
    /// git holds no versions of it: resolved since the badge was drawn, or never conflicted.
    case notConflicted
    /// Ours deleted it and theirs changed it (`DU`).
    case deletedByUs
    /// Theirs deleted it and ours changed it (`UD`).
    case deletedByThem
    /// Both deleted it (`DD`), as a rename to two different names leaves the old one.
    case deletedByBoth
    /// Only ours has it (`AU`), as each of those two new names is left.
    case addedByUs
    /// Only theirs has it (`UA`).
    case addedByThem
    /// A version is a symbolic link or a submodule rather than a file.
    case notAFile
}

/// The versions a merge of one conflicted path is made from (PLAN.md §M34 Slice 5).
public struct GitConflictStages: Sendable, Equatable {
    /// The common ancestor, or `nil` when both sides added the file (`AA`), whose merge starts
    /// from an empty one.
    public let base: GitStage?
    public let ours: GitStage
    public let theirs: GitStage

    /// The versions in `stages`, git's listing for one path, or why there is nothing to merge.
    ///
    /// Read from the stages rather than from the status letters, which a snapshot drew earlier:
    /// this is what git holds as the gesture runs. Both sides have to be there. A deletion or a
    /// version only one side has leaves no one file to write, since keeping it or not is
    /// `git add` against `git rm`, a choice no merge makes.
    public static func choose(from stages: [GitStage]) throws(GitConflictRefusal) -> GitConflictStages {
        func stage(_ number: Int) -> GitStage? {
            stages.first { $0.number == number }
        }
        let base = stage(1)
        switch (stage(2), stage(3)) {
        case let (ours?, theirs?):
            guard [base, ours, theirs].allSatisfy({ $0?.isFile ?? true }) else { throw .notAFile }
            return GitConflictStages(base: base, ours: ours, theirs: theirs)
        case (nil, _?):
            throw base == nil ? .addedByThem : .deletedByUs
        case (_?, nil):
            throw base == nil ? .addedByUs : .deletedByThem
        case (nil, nil):
            throw base == nil ? .notConflicted : .deletedByBoth
        }
    }
}

/// What git is in the middle of while a file is conflicted, which says what ours and theirs are.
///
/// In a merge ours is the branch checked out. In a rebase it is the branch being rebased onto,
/// and theirs is the commit being replayed, so a merge window titled by git's sides alone would
/// read backwards there.
public enum GitOperation: Sendable, Equatable, CaseIterable {
    case merge
    case rebase
    case cherryPick
    case revert
    /// `git am -3`, applying patches from mail.
    case applyingPatches
    /// Anything that leaves no marker: `git stash pop`, `git checkout -m`.
    case other

    /// The operation the git directory at `gitDirectory` records. `exists` is a plain existence
    /// check, as `GitRepository.repositoryRoot(for:exists:)`'s is.
    ///
    /// The markers, probed on git 2.54 in each operation and from a linked worktree, whose markers
    /// are in its own git directory: `rebase-merge/` for a rebase, `rebase-apply/` for an older
    /// rebase and for `git am`, which alone writes `rebase-apply/applying`, `MERGE_HEAD`,
    /// `CHERRY_PICK_HEAD` and `REVERT_HEAD`. A rebase is asked first: one that stops on a merge
    /// commit writes `MERGE_HEAD` too, and ours is still the branch being rebased onto.
    public static func inProgress(gitDirectory: String, exists: (String) -> Bool) -> GitOperation {
        func has(_ name: String) -> Bool {
            exists(gitDirectory + "/" + name)
        }
        if has("rebase-merge") { return .rebase }
        if has("rebase-apply") { return has("rebase-apply/applying") ? .applyingPatches : .rebase }
        if has("MERGE_HEAD") { return .merge }
        if has("CHERRY_PICK_HEAD") { return .cherryPick }
        if has("REVERT_HEAD") { return .revert }
        return .other
    }
}
