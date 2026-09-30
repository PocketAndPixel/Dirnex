import AppKit
import DirnexCore

/// The **decisions** behind putting an edited remote file back on the server it came from
/// (PLAN.md §M21 Slice 10) — what the check found, what precondition the write carries, and what a
/// refusal means.
///
/// The flow that runs them is `+WriteBackBatch`, which gathers saves into one queued job. The split
/// is by concept and not by line count: everything here is pure and `static`, so the rules and
/// their wording are testable with no window, no server and no queue — which is what let the flow
/// underneath them be rewritten (2026-09-01) with the sentences the user reads left untouched.
///
/// The window owns both halves for the reason the archive write-back lives here: an edit outlives
/// whatever the panes are showing. Someone can open a file off a bucket, navigate both panes
/// elsewhere, close the tab, and save an hour later — and the answer still has to be "put it back".
///
/// **It re-`stat`s before it writes, and only *asks* when that answered something.** None of the
/// three remote protocols has a lock, and an upload is a whole-file write: S3's is a whole-object
/// `PUT`. So the ordinary hazard is not the transfer failing, it is the transfer *succeeding* and
/// silently erasing an edit somebody else made in the meantime, with nothing on screen at any point
/// to say so. One request answers that, and it is asked before anything is shown rather than after
/// the user has agreed — so whatever they are being told is the true thing.
///
/// **A check that found nothing uploads straight away** (2026-08-23). What raises this is the user's
/// own ⌘S, and the watch deliberately outlives an upload (`EditedFileRegistry.stopWatching`) — so a
/// dialog on the unchanged case is a confirmation of an intent already stated, once per save, for
/// the life of the edit, while the local F4 this is the twin of asks nothing at all. The archive
/// arm's reason for asking does not carry over either: a repack rewrites the whole container and
/// every other member with it, where an upload replaces the one file being edited with the version
/// just saved, which is what "save" means. What survives is the question actually worth a modal —
/// somebody else wrote this file, or the check could not be made — plus a status line, so a silent
/// save is still a visible one.
///
/// **The blind spots that used to be worded are why that is defensible, not an argument against
/// it.** An FTP `LIST` stamp is year-less, zone-less and on the server's clock, so "same size and
/// date" over FTP misses most of a working day — and the dialog saying so offered two buttons
/// resting on that same weak evidence, with no way for the user to strengthen it, and the same
/// sentence again on the next save. Reporting a caveat nobody can act on is what
/// `RemoteFileRevision` already refuses to do with a confidence percentage; this is that rule one
/// layer out. The four-way `RemoteRevisionEvidence` that graded those blind spots went with the
/// wording it existed to produce, so `isSuperseded(by:)` is now the whole of the comparison.
extension BrowserWindowController {
    /// What the re-`stat` found, in the user's terms — or `nil` when it found nothing worth saying.
    ///
    /// The split that decides whether anybody is interrupted is not "changed / unchanged": it is
    /// whether the check produced a **fact the user has to weigh**. Three answers do, and each is
    /// something no other surface would ever tell them — the server's copy moved under the edit, the
    /// check could not be made, or nothing was recorded to compare against. The fourth is "the file
    /// is as you left it", which is what pressing ⌘S already assumed, and handing that back as a
    /// question is the redundancy `nil` exists for.
    ///
    /// Note what is deliberately *not* weighed, having been the whole subject of this function
    /// until 2026-08-23: **how much an unchanged verdict is worth**, which differs sharply by
    /// protocol. Every word of the four sentences that said so was true — and each named a weakness
    /// the reader could do nothing about from here, since both buttons rested on exactly that
    /// evidence and declining produced the same sentence again on the next save. The core type that
    /// graded it was removed with them, so `isSuperseded(by:)` is now the whole comparison.
    ///
    /// `static` and pure so both the decision and its wording are testable without a window.
    static func writeBackConcern(
        recorded: RemoteFileRevision?,
        current: RemoteFileRevision?
    ) -> String? {
        let overwrite = String(
            localized: "Uploading replaces the copy on the server and can’t be undone.",
            comment: "Sentence appended to every remote write-back prompt."
        )
        guard let current else {
            return String(
                localized: """
                Dirnex couldn’t reach the file on the server to check whether it has \
                changed. \(overwrite)
                """,
                comment: """
                Remote write-back body when the pre-upload check failed; %@ is the shared \
                “uploading replaces…” sentence.
                """
            )
        }
        guard let recorded else {
            return String(
                localized: """
                Dirnex has no record of what this file looked like when it was downloaded, so it \
                can’t tell whether anyone has changed it since. \(overwrite)
                """,
                comment: """
                Remote write-back body when nothing was recorded to compare against; %@ is the \
                shared “uploading replaces…” sentence.
                """
            )
        }
        guard !recorded.isSuperseded(by: current) else {
            return String(
                localized: """
                The file on the server has changed since you downloaded it — someone else has \
                edited it. \(overwrite)
                """,
                comment: """
                Remote write-back body when the server's copy was modified in the meantime; %@ is \
                the shared “uploading replaces…” sentence.
                """
            )
        }
        return nil
    }

    // MARK: - The precondition

    /// The precondition a save-back attaches, read off **the revision the check just found** rather
    /// than off the one that was downloaded (PLAN.md §M21 Slice 18).
    ///
    /// This is the load-bearing line of the whole wiring, and the natural way round breaks the
    /// feature outright: conditioning on the *download's* tag would refuse exactly the write the
    /// prompt exists to authorize. Someone told "the file on the server has changed — someone else
    /// has edited it" who then presses Upload has said they mean to replace *that* version, and an
    /// `If-Match` naming the older tag answers 412 to their own decision, in a sentence claiming
    /// somebody changed the file. So the check's tag is what travels: it pins what they agreed to
    /// overwrite, which is precisely the window `RemoteFileRevision` cannot cover — between the
    /// answer and the `PUT` (`S3WriteCondition`).
    ///
    /// `.unconditional` for everything else, and that is the additive design rather than a gap.
    /// SFTP and FTP have no entity tag, a check that could not reach the server has nothing to pin,
    /// and an S3 row whose listing carried no `<ETag>` is the same case — each goes on resting on
    /// the re-`stat` this whole flow is decided from, which is where they were before this
    /// slice. Never worse, and never claiming more.
    static func writeCondition(checked current: RemoteFileRevision?) -> S3WriteCondition {
        guard let entityTag = current?.entityTag else { return .unconditional }
        // Verbatim, quotes included: an unquoted digest is a different byte string to S3 and
        // matches nothing, so tidying them away would turn every conditional save into a 412
        // reading "somebody else changed this file" (docs/NOTES.md ▸ curl for S3).
        return .ifMatches(entityTag: entityTag)
    }

    // MARK: - When the server says no

    /// Whether `error` is the server refusing the precondition, as opposed to anything else that
    /// can go wrong on the way up.
    ///
    /// Narrow on purpose, and the narrowness is the point: a 403 on a conditional upload is still a
    /// permissions problem, and offering to "upload anyway" over one would be an offer that cannot
    /// work — it would fail identically, having asked the user to authorize an overwrite that never
    /// happens. Only the two refusals the condition itself produces get the second question.
    ///
    /// `static` and pure so both the classification and its wording are testable without a window.
    static func writeBackConflict(from error: any Error) -> RemoteWriteBackConflict? {
        guard case let VFSError.unsupported(reason) = error else { return nil }
        switch reason {
        case .remoteFileChangedSinceFetch: return .changed
        case .remoteFileGoneSinceFetch: return .gone
        default: return nil
        }
    }

    /// What the server refused, and what uploading anyway would do about it.
    ///
    /// Two sentences rather than one, because the user's situation genuinely differs: a *changed*
    /// object has a newer version that uploading destroys, while a *gone* one has nothing to
    /// destroy and nothing to compare with — so "replaces their version" would be false there, and
    /// "puts it back" would be false in the other direction.
    ///
    /// `static` and pure so the wording is testable without a window, exactly like
    /// ``writeBackConcern(recorded:current:)``.
    static func uploadAnywayBody(_ conflict: RemoteWriteBackConflict) -> String {
        switch conflict {
        case .changed:
            String(
                localized: """
                The server refused the upload: somebody wrote to this file between Dirnex checking \
                it and the upload starting. Uploading anyway replaces their version and can’t be \
                undone.
                """,
                comment: """
                Body of the upload-anyway prompt when the server refused the guarded upload because \
                the file changed in the meantime.
                """
            )
        case .gone:
            String(
                localized: """
                The server refused the upload: this file isn’t there any more — somebody has \
                deleted or moved it. Uploading anyway puts it back as a new file.
                """,
                comment: """
                Body of the upload-anyway prompt when the server refused the guarded upload because \
                the file no longer exists.
                """
            )
        }
    }
}

/// Why a guarded save-back was refused, in the two shapes the user's next step differs between
/// (PLAN.md §M21 Slice 18).
///
/// A translation of the core's `S3WriteConditionRefusal` rather than a re-export of it, and
/// deliberately one case narrower: `.alreadyThere` answers an `.ifAbsent` write, which a save-back
/// never sends. Carrying it here would put an unreachable arm in front of every reader of this type
/// and invite a sentence nobody can ever see.
enum RemoteWriteBackConflict: Equatable {
    /// The object changed between the check and the upload — there is a newer version, and
    /// uploading destroys it.
    case changed
    /// The object is gone — nothing to overwrite, and nothing to compare against.
    case gone
}
