import DirnexCore
import Foundation

/// The words of Resolve Conflict… (PLAN.md §M34 Slice 5): what each pane of the merge is, and why a
/// merge did not open.
///
/// The panes are titled Yours and Theirs, as for a server file. Under each title is what that side
/// is in the operation git is in the middle of, because the sides are git's: ours is `HEAD`, which
/// in a rebase is the branch being rebased onto, and theirs is then the user's own commit being
/// replayed. The refusals do not say which side deleted a file, for the same reason.
extension PanelViewController {
    nonisolated static func resolveFailureTitle(_ name: String) -> String {
        String(
            localized: "Couldn’t resolve the conflict in “\(name)”",
            comment: """
            Alert title when Resolve Conflict… can't open the merge of a file git left conflicted; %@ \
            is its name.
            """
        )
    }

    static func resolveFailureDetail(_ failure: ConflictReadFailure) -> String {
        switch failure {
        case let .text(failure):
            CompareOpener.failureDetail(failure)
        case let .git(.refused(refusal)):
            refusalDetail(refusal)
        case .git(.tooLarge):
            CompareOpener.limitDetail(ByteComparator.prescanByteLimit)
        case let .git(.gitFailed(failure)) where failure.message.isEmpty:
            String(
                localized: "git couldn’t read the file’s versions.",
                comment: "Resolve Conflict failure detail when git exited with an error and said nothing."
            )
        case let .git(.gitFailed(failure)):
            String(
                localized: "git couldn’t read the file’s versions. It said: \(failure.message)",
                comment: "Resolve Conflict failure detail; %@ is git's own error message, in English."
            )
        }
    }

    private nonisolated static func refusalDetail(_ refusal: GitConflictRefusal) -> String {
        switch refusal {
        case .notConflicted:
            String(
                localized: "git no longer lists a conflict in this file. It may have been resolved since.",
                comment: "Resolve Conflict failure detail when git holds no conflict for the file any more."
            )
        case .deletedByUs, .deletedByThem:
            String(
                localized: """
                One side deleted the file and the other changed it, so there’s no one file to merge. \
                Keep it with git add, or remove it with git rm.
                """,
                comment: "Resolve Conflict failure detail; git add and git rm are commands, not to be translated."
            )
        case .deletedByBoth:
            String(
                localized: "Both sides deleted the file, so there’s nothing to merge. Remove it with git rm.",
                comment: "Resolve Conflict failure detail; git rm is a command, not to be translated."
            )
        case .addedByUs, .addedByThem:
            String(
                localized: """
                Only one side has the file under this name, so there’s nothing to merge it with. Keep \
                it with git add, or remove it with git rm.
                """,
                comment: """
                Resolve Conflict failure detail, as when each side renamed a file differently; git add \
                and git rm are commands, not to be translated.
                """
            )
        case .notAFile:
            String(
                localized: """
                One side has a symbolic link or a submodule here rather than a file, so there’s no \
                text to merge.
                """,
                comment: "Resolve Conflict failure detail."
            )
        }
    }

    // MARK: - The panes

    nonisolated static var conflictBaseDetail: String {
        String(
            localized: "The common ancestor",
            comment: "Merge window, under Base, for a git conflict: the version both sides started from."
        )
    }

    nonisolated static var conflictNoBaseDetail: String {
        String(
            localized: "None: both sides added the file",
            comment: "Merge window, under Base, for a git conflict where each side added the same file."
        )
    }

    /// Ours, which is `HEAD` in every operation.
    nonisolated static func conflictYoursDetail(_ operation: GitOperation) -> String {
        switch operation {
        case .rebase:
            String(
                localized: "HEAD, the branch being rebased onto",
                comment: "Merge window, under Yours, during a git rebase. HEAD is git's name, not to be translated."
            )
        case .merge, .cherryPick, .revert, .applyingPatches:
            String(
                localized: "HEAD, the branch you’re on",
                comment: "Merge window, under Yours, for a git conflict. HEAD is git's name, not to be translated."
            )
        case .other:
            "HEAD"
        }
    }

    /// Theirs, which is what the operation brings in.
    nonisolated static func conflictTheirsDetail(_ operation: GitOperation) -> String {
        switch operation {
        case .merge:
            String(
                localized: "The branch being merged in",
                comment: "Merge window, under Theirs, during a git merge."
            )
        case .rebase:
            String(
                localized: "The commit being replayed",
                comment: "Merge window, under Theirs, during a git rebase: the user's own commit."
            )
        case .cherryPick:
            String(
                localized: "The commit being picked",
                comment: "Merge window, under Theirs, during a git cherry-pick."
            )
        case .revert:
            String(
                localized: "The commit being reverted, undone",
                comment: "Merge window, under Theirs, during a git revert: the reverted commit's change, taken back."
            )
        case .applyingPatches:
            String(
                localized: "The patch being applied",
                comment: "Merge window, under Theirs, during git am."
            )
        case .other:
            String(
                localized: "The changes being merged in",
                comment: """
                Merge window, under Theirs, for a git conflict whose operation git doesn't record, such \
                as a stash pop.
                """
            )
        }
    }

    /// Where the result goes, without its path: the window's title names the file, and a working
    /// tree's path is long enough that a pane's subtitle cut the sentence in two (seen live).
    nonisolated static var conflictResultDetail: String {
        String(
            localized: "Saved to the working tree; git add marks it resolved",
            comment: """
            Merge window, under Result, for a git conflict: Save writes the file in the working \
            tree, and staging it is the user's. git add is a command, not to be translated.
            """
        )
    }
}
