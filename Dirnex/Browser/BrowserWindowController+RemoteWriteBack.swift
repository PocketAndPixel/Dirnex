import AppKit
import DirnexCore

/// Putting an edited remote file back on the server it came from (PLAN.md §M21 Slice 10).
///
/// The window owns this for the reason the archive write-back lives here: an edit outlives whatever
/// the panes are showing. Someone can open a file off a bucket, navigate both panes elsewhere, close
/// the tab, and save an hour later — and the answer still has to be "put it back".
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
    /// A watched copy of a remote file has been saved — check the server, then upload it or ask.
    func offerRemoteWriteBack(_ edit: EditedFile, to path: VFSPath) {
        let backend = focusedPanel.backend
        let recorded = remoteFileCache.revision(for: path)
        Task {
            let current = await BlockingWork.run { try? backend.stat(at: path) }
            let checked = current.map(RemoteFileRevision.init)
            let condition = Self.writeCondition(checked: checked)
            guard let concern = Self.writeBackConcern(recorded: recorded, current: checked) else {
                // Nothing to weigh, so nothing to interrupt for: this is the save the user asked
                // for, landing where they asked for it.
                uploadEditedFile(edit, to: path, condition: condition)
                return
            }
            presentRemoteWriteBackOffer(edit, to: path, concern: concern, condition: condition)
        }
    }

    /// The one dialog, raised only when ``writeBackConcern(recorded:current:)`` had something to say
    /// and worded by it.
    private func presentRemoteWriteBackOffer(
        _ edit: EditedFile,
        to path: VFSPath,
        concern: String,
        condition: S3WriteCondition
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Upload “\(edit.name)” back to the server?",
            comment: """
            Title of the write-back prompt after a file downloaded from a server was edited; %@ is \
            the file's name.
            """
        )
        alert.informativeText = concern
        alert.addButton(withTitle: String(
            localized: "Upload",
            comment: "Button that uploads an edited file back to the server it came from."
        ))
        alert.addButton(withTitle: String(
            localized: "Keep Editing",
            comment: """
            Button that declines uploading an edited file, leaving the editor open so the user can \
            save again later.
            """
        ))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which neither button is —
        // so the response, not the title, is what says which one ⎋ means (docs/NOTES.md).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.uploadEditedFile(edit, to: path, condition: condition)
        }
        // The watcher raised this, not the user — see `beginSheetIfVisible`.
        alert.beginSheetIfVisible(over: window, completionHandler: handler)
    }

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

    // MARK: - The upload

    /// Send the edited copy back up, then re-baseline what a *second* save will compare against.
    ///
    /// The write is routed to the backend that can carry `condition` when there is one, and to the
    /// ordinary `copyFile` when there is not — never the other way about. A conditional call that
    /// quietly lost its precondition is the one outcome worse than not having the feature, which is
    /// why the seam beneath this throws rather than dropping it (`S3WriteConditionUnsupported`).
    ///
    /// **It says so afterwards**, on the status line rather than in an alert, because since
    /// 2026-08-23 the ordinary save reaches here having asked nothing — and an upload that leaves no
    /// trace on screen is indistinguishable from one that never happened. Reported unconditionally,
    /// including on the paths that *did* ask: a second surface saying the same thing costs a line
    /// nobody has to dismiss, where a branch on how the user got here is a rule to keep right.
    /// Failures keep their alert; this is the routine half, which is the half a modal is wrong for.
    private func uploadEditedFile(
        _ edit: EditedFile,
        to path: VFSPath,
        condition: S3WriteCondition
    ) {
        let backend = focusedPanel.backend
        let writer = condition.isConditional
            ? (backend as? CompositeBackend)?.conditionalWriter(for: path)
            : nil
        let source = VFSPath.local(edit.temporaryURL.path)
        let url = edit.temporaryURL
        Task {
            let outcome = await BlockingWork.run { () -> Result<Void, any Error> in
                Result {
                    guard let writer else {
                        return try backend.copyFile(
                            at: source, to: path, progress: { _ in }, isCancelled: { false }
                        )
                    }
                    // The answer — whether the precondition actually travelled — is deliberately
                    // not shown anywhere: a file over the multipart threshold reports `false`, and
                    // the prompt the user already agreed to never claimed the write was guarded.
                    // It rests on the re-`stat`, which works on every server and in every size.
                    // Saying "this large save was not protected" would be announcing the absence
                    // of a protection nothing had promised (`S3ConditionalWrite`).
                    try writer.upload(
                        localPath: url.path,
                        over: path,
                        condition: condition,
                        progress: { _ in },
                        isCancelled: { false }
                    )
                }
            }
            do {
                try outcome.get()
            } catch {
                presentWriteBackFailure(error, edit: edit, to: path)
                return
            }
            // The watch deliberately stays: unlike a repack, an upload changes nothing on this Mac,
            // the editor still has this very file open, and a second save has to come back through
            // here (`EditedFileRegistry.stopWatching`). What must move is the revision the next check
            // compares against — leaving the pre-upload one would have our own write read back as
            // "someone else has edited it", which is the one sentence that must never be wrong.
            await rebaseline(path, to: url, using: backend)
            refreshPanesShowing(path.parent)
            // On the focused pane, not on whichever pane is drawing the directory: this reports
            // where the user's attention is, and both of them may have navigated away during an
            // edit that took an hour.
            focusedPanel.showTransientStatus(String(
                localized: "Uploaded “\(edit.name)” to the server",
                comment: """
                Status line shown after an edited file was uploaded back to the server it came \
                from; %@ is the file's name.
                """
            ))
        }
    }

    // MARK: - When the server says no

    /// Report a failed upload — or, when the *precondition* is what refused it, offer the way
    /// through rather than a dead end.
    ///
    /// A refused precondition is not a malfunction: it means the object moved under us in the
    /// window between the check and the `PUT`, which is the exact race this slice added the header
    /// for. The user has already answered one question about overwriting and is entitled to answer
    /// this one, so the sentence arrives as a *decision* rather than as an error with an OK button
    /// — otherwise the only route left is saving again in the editor, and an editor asked to save a
    /// file it has not changed may write nothing for the watcher to notice.
    private func presentWriteBackFailure(_ error: any Error, edit: EditedFile, to path: VFSPath) {
        guard let conflict = Self.writeBackConflict(from: error) else {
            focusedPanel.presentOperationFailure(
                message: String(
                    localized: "Couldn’t upload “\(edit.name)”",
                    comment: """
                    Alert title when uploading an edited file back to its server fails; %@ is the \
                    file's name.
                    """
                ),
                detail: focusedPanel.describe(error)
            )
            return
        }
        presentUploadAnywayOffer(conflict, edit: edit, to: path)
    }

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

    /// The second question, asked once and never in a loop: the retry is **unconditional**, so it
    /// cannot come back here.
    ///
    /// That is a decision rather than a shortcut. Re-reading the object and conditioning on the new
    /// tag would be more precise and could be refused again by a third writer, which is a loop with
    /// a round trip in it (the same shape the FTPS trust retry had to guard against); and the user
    /// has now been told twice, so a third round trip has nothing left to tell them. An
    /// unconditional write is exactly what this save would have done before this slice existed.
    private func presentUploadAnywayOffer(
        _ conflict: RemoteWriteBackConflict,
        edit: EditedFile,
        to path: VFSPath
    ) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Upload “\(edit.name)” anyway?",
            comment: """
            Title of the prompt shown when the server refused a conditional save-back; %@ is the \
            file's name.
            """
        )
        alert.informativeText = Self.uploadAnywayBody(conflict)
        alert.addButton(withTitle: String(
            localized: "Upload Anyway",
            comment: """
            Button that uploads an edited file over the server's copy after the server refused the \
            guarded upload.
            """
        ))
        alert.addButton(withTitle: String(
            localized: "Keep Editing",
            comment: """
            Button that declines uploading an edited file, leaving the editor open so the user can \
            save again later.
            """
        ))
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.uploadEditedFile(edit, to: path, condition: .unconditional)
        }
        // The chain this continues was raised by the edit watcher, not by a key anybody pressed, so
        // a window that has gone away in the meantime has nobody to ask (`beginSheetIfVisible`).
        alert.beginSheetIfVisible(over: window, completionHandler: handler)
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

    /// Re-read what the server now holds and record it as the copy's revision.
    ///
    /// A failed read drops the entry instead of keeping the stale one: with nothing recorded the
    /// next save says plainly that it cannot tell, which is true, where a stale revision would say
    /// something false with confidence.
    private func rebaseline(_ path: VFSPath, to url: URL, using backend: any VFSBackend) async {
        let uploaded = await BlockingWork.run { try? backend.stat(at: path) }
        guard let uploaded else {
            remoteFileCache.drop(path)
            return
        }
        remoteFileCache.rebaseline(path, to: RemoteFileRevision(uploaded), url: url)
    }

    /// Re-list any pane drawing `directory`, so the size and date it shows for the object are the
    /// ones just written.
    ///
    /// Both panes, by *content* rather than by role — the pane that opened the file may have
    /// navigated away, both may be in the same directory, or neither may be. The same "ask which
    /// pane is showing this, don't assume" shape the archive write-back and the pack outcome need.
    ///
    /// Through `isShowing`, not `panel.path ==`, and that is the whole of the 2026-08-22 fix: a tree
    /// draws several directories at once, so an object edited from an account pane with its bucket
    /// expanded is two levels below the path this used to compare against. The upload succeeded and
    /// the row kept the size and date it had.
    private func refreshPanesShowing(_ directory: VFSPath?) {
        guard let directory else { return }
        for pane in [leftPanel, rightPanel] where pane.isShowing(directory) {
            pane.refreshCurrentDirectory()
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
