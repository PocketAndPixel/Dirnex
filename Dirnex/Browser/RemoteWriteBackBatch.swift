import DirnexCore
import Foundation

/// One save-back's worth of decision: the edit, where it goes, what the check found, and what the
/// user was therefore asked (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// A value rather than five parallel arrays, because the whole point of the batch is that these
/// travel together — the item that gets uploaded has to be the one whose concern was named in the
/// sheet, and the precondition has to be the one read off *that* check.
struct CheckedWriteBack: Equatable {
    let edit: EditedFile
    let destination: VFSPath
    /// What the re-`stat` found worth saying, or `nil` when it found nothing — the same answer
    /// `BrowserWindowController.writeBackConcern` has always produced, gathered rather than acted
    /// on one at a time.
    let concern: String?
    let condition: S3WriteCondition
    let byteSize: Int64

    var hasConcern: Bool { concern != nil }
}

/// What the user is asked about a checked batch, and what each answer means.
///
/// Three outcomes rather than two, and the middle one is why the sheet exists at all: a batch is
/// rarely all-or-nothing. Thirty-seven files nobody touched and three somebody did is the ordinary
/// shape of a script run against a shared server, and both of the simple answers are bad there —
/// "upload all" overwrites work the user has not seen, and "cancel" throws away thirty-seven edits
/// they would then have to re-trigger by saving again in an editor that may write nothing because
/// nothing changed.
enum WriteBackAnswer: Equatable {
    /// Upload everything, contested items included.
    case all
    /// Upload only what the check found nothing to say about, leaving the rest watched so the user
    /// can look at them and save again.
    case clean
    /// Upload nothing.
    case none
}

/// Deciding what a batch of checked save-backs should do, with no window and no server
/// (PLAN.md §4 ▸ *Still open*).
///
/// Split from the flow that presents it for the reason this project splits every such rule out:
/// what is worth pinning is *which items are uploaded for a given answer* and *whether anybody is
/// asked at all*, and a test that presents a real sheet in the test host destabilizes its
/// neighbours (docs/NOTES.md ▸ Testing).
enum WriteBackBatchPlan {
    /// Whether this batch needs to interrupt anybody.
    ///
    /// The rule the single-save path has followed since 2026-08-23, applied to a set: a check that
    /// found nothing is not a question, it is the save the user already asked for. So a batch of
    /// forty whose files nobody touched goes up in silence — which is the common case, since the
    /// copies were downloaded minutes earlier by the same gesture that rewrote them.
    static func needsConfirmation(_ checked: [CheckedWriteBack]) -> Bool {
        checked.contains { $0.hasConcern }
    }

    /// The items `answer` uploads, in the order they were checked.
    ///
    /// Order is the batch's own: the ordering the gap was about is that these go up one after
    /// another in a known sequence rather than as N races, and a plan that re-sorted them would be
    /// quietly inventing a second one.
    static func items(for answer: WriteBackAnswer, from checked: [CheckedWriteBack]) -> [
        CheckedWriteBack
    ] {
        switch answer {
        case .all: checked
        case .clean: checked.filter { !$0.hasConcern }
        case .none: []
        }
    }

    /// The job those items become.
    static func job(for items: [CheckedWriteBack]) -> WriteBackJob {
        WriteBackJob(items: items.map {
            RemoteWriteBackItem(
                localPath: $0.edit.temporaryURL.path,
                destination: $0.destination,
                condition: $0.condition,
                byteSize: $0.byteSize,
                name: $0.edit.name
            )
        })
    }
}
