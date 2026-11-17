import DirnexCore
import Foundation

/// What the copy and move dialog says (PLAN.md §M41).
///
/// Whole sentences per kind rather than a verb spliced into a template, since a language that
/// inflects the object or reorders the clause cannot build one from a bare verb (docs/NOTES.md ▸
/// Localization). Counts are labelled numbers where a sentence would need plural agreement on a
/// line that changes many times a second, the rule `SearchProgressSheet.describe` set; the one
/// question that counts in a sentence carries its plural forms in the catalog.
@MainActor
enum TransferDialogText {
    /// The confirmation's question: what goes, and that the path below is where.
    static func question(_ summary: TransferSummary) -> String {
        if summary.sources.count == 1, let name = summary.sources.first?.name {
            return summary.kind == .move
                ? String(
                    localized: "Move “\(name)” to:",
                    comment: "Copy dialog question for one item; %@ is its name. The folder follows on its own line."
                )
                : String(
                    localized: "Copy “\(name)” to:",
                    comment: "Copy dialog question for one item; %@ is its name. The folder follows on its own line."
                )
        }
        let count = summary.sources.count
        return summary.kind == .move
            ? String(
                localized: "Move \(count) items to:",
                comment: "Copy dialog question for several items; %lld is how many. The folder follows on its own line."
            )
            : String(
                localized: "Copy \(count) items to:",
                comment: "Copy dialog question for several items; %lld is how many. The folder follows on its own line."
            )
    }

    /// The progress dialog's title, naming the folder the items go into.
    static func title(kind: FileOperation.Kind, destination: VFSPath) -> String {
        let folder = destination.isRoot ? location(destination) : destination.lastComponent
        return kind == .move
            ? String(
                localized: "Moving to “\(folder)”",
                comment: "Copy progress dialog title for a move; %@ is the folder the items go into."
            )
            : String(
                localized: "Copying to “\(folder)”",
                comment: "Copy progress dialog title; %@ is the folder the items go into."
            )
    }

    /// Where `path` is, the way Synchronize's header says it: a local path with `~` for home, a
    /// server's with the server's name in front, since a `~` there would name this Mac's home.
    static func location(_ path: VFSPath) -> String {
        guard let root = path.backendRootTitle else {
            return (path.path as NSString).abbreviatingWithTildeInPath
        }
        return path.isRoot ? root : "\(root)\(path.path)"
    }

    /// The line above the bars: the file being written, or why nothing is.
    static func status(_ state: TransferDialogState) -> String {
        switch state.phase {
        case .preparing:
            String(
                localized: "Preparing…",
                comment: "Queue-bar status before any operation has started transferring."
            )
        case .waiting:
            String(
                localized: "Waiting for its turn in the queue…",
                comment: "Copy progress dialog: this copy is queued behind another operation on the same disks."
            )
        case .paused:
            String(
                localized: "Paused",
                comment: "Queue row status: the operation is paused."
            )
        case .running, .done:
            (state.currentFile ?? state.currentItem)?.lastComponent ?? ""
        }
    }

    /// The readout under the bars: the queue bar's bytes, rate and time left, then the file count.
    static func detail(
        _ state: TransferDialogState,
        bytesPerSecond: Double,
        estimatedTimeRemaining: TimeInterval?
    ) -> String {
        let aggregate = AggregateProgress(
            totalJobs: 1,
            finishedJobs: 0,
            activeJobs: 1,
            totalBytes: state.totalBytes,
            completedBytes: state.completedBytes,
            bytesPerSecond: bytesPerSecond,
            estimatedTimeRemaining: estimatedTimeRemaining
        )
        var text = QueueBarView.detailText(for: aggregate, paused: state.phase != .running)
        // "Files: 0 of 1" says nothing the bytes do not, for the reason the dialog then shows one bar.
        if state.totalFiles > 1 {
            let done = min(state.completedFiles, state.totalFiles)
            text += " · " + String(
                localized: "Files: \(done) of \(state.totalFiles)",
                comment: "Copy progress dialog: %1$lld files copied so far, of %2$lld in all."
            )
        }
        return text
    }

    /// The question Cancel asks, with the job paused behind it.
    static func stopQuestion(kind: FileOperation.Kind) -> (message: String, detail: String) {
        kind == .move
            ? (
                String(
                    localized: "Stop moving?",
                    comment: "Copy progress dialog: Cancel asks this for a move."
                ),
                String(
                    localized: "What was already moved stays where it is now, and ⌘Z puts it back.",
                    comment: "Copy progress dialog: what stopping a move leaves behind."
                )
            )
            : (
                String(
                    localized: "Stop copying?",
                    comment: "Copy progress dialog: Cancel asks this for a copy."
                ),
                String(
                    localized: "What was already copied stays where it is, and ⌘Z undoes it.",
                    comment: "Copy progress dialog: what stopping a copy leaves behind."
                )
            )
    }
}
