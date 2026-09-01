import AppKit
import DirnexCore

/// What a finished save-back batch says, and the one question it can still have to ask
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// Split from the flow for the reason its decisions are: everything the user reads is `static` and
/// pure, so the sentences are testable with no window and no server — which matters more here than
/// usual, because a batch has four endings (everything landed, some did not, the server refused a
/// precondition, the user stopped it) and each says something different.
extension BrowserWindowController {
    /// Say what the batch did, and re-offer whatever the server refused on a precondition.
    ///
    /// **The routine half is a status line, never a dialog** — the rule the single save has followed
    /// since 2026-08-23, and it matters more in a batch: an upload that leaves no trace on screen is
    /// indistinguishable from one that never happened, and forty of them is forty chances to look
    /// like nothing happened. Failures keep an alert, which is the half a modal is right for.
    func reportWriteBacks(
        _ chosen: [CheckedWriteBack],
        landed: Set<VFSPath>,
        report: OperationReport
    ) {
        let uploaded = chosen.filter { landed.contains($0.destination) }
        if !uploaded.isEmpty {
            focusedPanel.showTransientStatus(
                Self.uploadedStatus(uploaded, wasCancelled: report.wasCancelled)
            )
        }
        // A refused **precondition** is a question rather than an error: the object moved in the
        // window between the check and the write, which is the exact race the header exists for,
        // and the user is entitled to answer it. Everything else is a failure and reads as one.
        let refused: [(item: CheckedWriteBack, conflict: RemoteWriteBackConflict)] = chosen
            .compactMap { item in
                guard let failure = report.failures.first(where: { $0.path == item.destination }),
                      let conflict = Self.writeBackConflict(from: failure.error) else { return nil }
                return (item, conflict)
            }
        let broken = report.failures.filter { Self.writeBackConflict(from: $0.error) == nil }
        if !broken.isEmpty {
            presentWriteBackFailures(broken)
        }
        guard !refused.isEmpty else { return }
        Task { await offerUploadAnyway(refused) }
    }

    /// The status line after a batch — one sentence whichever size it was.
    ///
    /// A count rather than the names past one file, because the status line truncates its **tail**
    /// in silence and an interpolated file name is unbounded (docs/NOTES.md ▸ Localization). One
    /// file keeps its name, which is what the user is thinking about when they pressed ⌘S.
    ///
    /// A stopped batch says so: some of its items really did go up, and a sentence claiming the
    /// whole batch landed would be wrong in the direction that matters — the user pressed Stop and
    /// is entitled to know it was not free.
    static func uploadedStatus(_ uploaded: [CheckedWriteBack], wasCancelled: Bool) -> String {
        if wasCancelled {
            let count = uploaded.count
            return String(
                localized: "Stopped — \(count) files had already been uploaded",
                comment: """
                Status line after a save-back batch was stopped partway; %lld is how many files had \
                already gone up.
                """
            )
        }
        guard uploaded.count > 1 else {
            let name = uploaded.first?.edit.name ?? ""
            return String(
                localized: "Uploaded “\(name)” to the server",
                comment: """
                Status line shown after an edited file was uploaded back to the server it came \
                from; %@ is the file's name.
                """
            )
        }
        let count = uploaded.count
        return String(
            localized: "Uploaded \(count) files to the server",
            comment: "Status line after a batch of edited files was uploaded; %lld is how many."
        )
    }

    /// The title over a save-back batch's one confirmation.
    static func writeBackPromptTitle(contested: [CheckedWriteBack], total: Int) -> String {
        guard total > 1 else {
            let name = contested.first?.edit.name ?? ""
            return String(
                localized: "Upload “\(name)” back to the server?",
                comment: """
                Title of the write-back prompt after a file downloaded from a server was edited; %@ \
                is the file's name.
                """
            )
        }
        let count = total
        return String(
            localized: "Upload \(count) edited files back to the server?",
            comment: "Title of the write-back prompt over a batch; %lld is how many files."
        )
    }

    /// What the checks found, in the user's terms.
    ///
    /// One file keeps the sentence it has always had — the batch must not make the ordinary save
    /// read like a report about a set. Past one, it says **how many** of the batch have something
    /// wrong and what the buttons will do about them, because naming forty files in a dialog is a
    /// wall nobody reads and naming three of forty without saying "of forty" is worse.
    static func writeBackPromptBody(contested: [CheckedWriteBack], total: Int) -> String {
        guard total > 1 else {
            return contested.first?.concern ?? ""
        }
        let count = contested.count
        let names = contested.prefix(3).map(\.edit.name).joined(separator: ", ")
        let overwrite = String(
            localized: "Uploading replaces the copies on the server and can’t be undone.",
            comment: "Sentence appended to the batch write-back prompt."
        )
        guard count < total else {
            return String(
                localized: """
                Dirnex couldn’t confirm that any of these files is still as it was downloaded — \
                somebody may have changed them, or the check couldn’t be made. \(overwrite)
                """,
                comment: """
                Batch write-back body when every file has a concern; %@ is the shared “uploading \
                replaces…” sentence.
                """
            )
        }
        return String(
            localized: """
            \(count) of them have changed on the server since they were downloaded, or couldn’t be \
            checked (\(names)). The rest are as you left them. \(overwrite)
            """,
            comment: """
            Batch write-back body naming how many files are contested; %1$lld is the count, %2$@ \
            the first few names, %3$@ the shared “uploading replaces…” sentence.
            """
        )
    }

    // MARK: - When the server refused a precondition

    /// Offer the way through for the items whose precondition the server refused.
    ///
    /// One question for the set, for the reason the check's is one question: this arrives when
    /// several objects moved in the same window, and N sheets in a row is what the whole slice
    /// exists to stop. The retry is **unconditional**, so it cannot come back here — re-reading and
    /// re-conditioning would be a loop with a round trip in it, and the user has now been told
    /// twice.
    private func offerUploadAnyway(
        _ refused: [(item: CheckedWriteBack, conflict: RemoteWriteBackConflict)]
    ) async {
        let items = refused.map(\.item)
        let alert = NSAlert()
        alert.messageText = Self.writeBackPromptTitle(contested: items, total: items.count)
        alert.informativeText = Self.uploadAnywayBody(Self.conflictKind(of: refused))
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
        let response = await alert.sheetAnswer(over: window, whenUnasked: .cancel)
        guard response == .alertFirstButtonReturn else { return }
        // Unconditional, and through the ordinary batch path so it gets the same bar and Stop.
        let retry = items.map {
            CheckedWriteBack(
                edit: $0.edit,
                destination: $0.destination,
                concern: nil,
                condition: .unconditional,
                byteSize: $0.byteSize
            )
        }
        await uploadWriteBacks(retry)
    }

    /// Which refusal to word the offer for.
    ///
    /// A set that disagrees takes `.changed`, and that is a choice rather than a fallback: the two
    /// sentences describe different situations, so a mixed set has no true one — *"this file isn't
    /// there any more"* said about three files of which one is missing is false about the other
    /// two. The changed wording is the half that is safe to be wrong in, because it warns about
    /// destroying a newer version, which is the outcome worth warning about. A set that agrees, and
    /// every single item, says exactly what happened.
    static func conflictKind(
        of refused: [(item: CheckedWriteBack, conflict: RemoteWriteBackConflict)]
    ) -> RemoteWriteBackConflict {
        let kinds = Set(refused.map(\.conflict))
        return kinds.count == 1 ? (kinds.first ?? .changed) : .changed
    }

    private func presentWriteBackFailures(_ failures: [OperationItemFailure]) {
        guard let first = failures.first else { return }
        focusedPanel.presentOperationFailure(
            message: failures.count > 1
                ? String(
                    localized: "Couldn’t upload \(failures.count) files",
                    comment: "Alert title when several edited files failed to upload; %lld is how many."
                )
                : String(
                    localized: "Couldn’t upload “\(first.path.lastComponent)”",
                    comment: """
                    Alert title when uploading an edited file back to its server fails; %@ is the \
                    file's name.
                    """
                ),
            detail: focusedPanel.describe(first.error)
        )
    }
}
