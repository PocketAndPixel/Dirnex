import AppKit
import DirnexCore

/// Gathering saved copies into batches, and carrying the **remote** half back as one queued job
/// (PLAN.md §4 ▸ *Still open*, taken 2026-09-01).
///
/// Until this, every save-back was its own `Task`: a user script that rewrote forty files on a
/// server produced forty independent uploads, each `stat`ing and uploading on its own — no combined
/// bar, no Stop, no ordering, and forty sheets if any of them had something to say. The download
/// direction had been the mirror of this since M24 Slice 2, so what was missing was the job kind
/// and the gathering in front of it, not a design.
///
/// **The gathering serves both endings.** An archive member's save had the same shape and a worse
/// cost — forty saves meant forty full repacks of one container, each extracting and re-compressing
/// everything the last had just written — so the batch is split by destination *after* it is
/// gathered rather than at the moment each save arrives (`+WriteBack`). One pacing rule, two
/// endings, which is what the write-back switch has always been.
///
/// **Every save-back comes through here, including a single ⌘S**, because two spellings of "upload
/// an edited file" is the shape this project keeps paying for and the two would drift the first
/// time the precondition or the re-baseline changed. `.materialize` settled the same question the
/// same way: a one-row Open With fetch is a queue job with no single-file branch.
///
/// **The gathering paces itself, and the one constant in it is borrowed rather than chosen.** A
/// batch opens on the first save and closes ``DirectoryWatcher/coalescingWindow`` later — the same
/// window each watcher is already holding its events for, so what this waits out is the delivery
/// mechanism rather than a guess about how fast a script writes. Anything that arrives while a
/// batch is checking or uploading joins the *next* one, which is what makes a slow script form a
/// few large batches instead of one per file, with no second timer and nothing to tune.
extension BrowserWindowController {
    /// Run batches until nothing is left waiting.
    ///
    /// The loop is the pacing: a batch takes everything pending, and whatever arrives during its
    /// checks and its upload is waiting when it comes back round. So the batch size is set by how
    /// long the previous one took rather than by a window somebody sized — a burst forms one batch,
    /// a script that writes a file every few seconds forms a few, and a lone ⌘S forms one of one.
    func gatherWriteBacks() async {
        defer { isGatheringWriteBacks = false }
        while !pendingWriteBacks.isEmpty {
            // Wait out the window the events themselves are coalesced over, so a burst that is
            // still arriving is one batch rather than a race between the first save and the rest.
            try? await Task.sleep(
                nanoseconds: UInt64(DirectoryWatcher.coalescingWindow * 1_000_000_000)
            )
            let batch = pendingWriteBacks
            pendingWriteBacks = []
            await runWriteBackBatch(batch)
        }
    }

    /// Split a batch by where its copies have to go, and run each ending.
    ///
    /// One after the other rather than together, so two sheets can never be up at once — and
    /// remote first only because that half asks *less often*: a clean set of uploads goes in
    /// silence, where every archive rewrite asks by construction.
    private func runWriteBackBatch(_ batch: [EditedFile]) async {
        let split = Self.split(batch)
        await runRemoteWriteBacks(split.remote)
        await runArchiveWriteBacks(split.members)
    }

    /// Which ending each save belongs to, in the order the batch gathered them.
    ///
    /// `static` and pure so the routing is assertable with no window, which is worth doing for the
    /// one failure here that would be quiet: an archive member handed to the remote ending would
    /// try to *upload to an `archive:` path* rather than repack, and the sentence the user would
    /// read is about a server they were never on.
    static func split(
        _ batch: [EditedFile]
    ) -> (remote: [PendingWriteBack], members: [PendingArchiveWriteBack]) {
        var remote: [PendingWriteBack] = []
        var members: [PendingArchiveWriteBack] = []
        for edit in batch {
            switch edit.destination {
            case let .remoteFile(path):
                remote.append((edit: edit, destination: path))
            case let .archiveMember(archivePath, innerDirectory):
                members.append(PendingArchiveWriteBack(
                    edit: edit, archivePath: archivePath, innerDirectory: innerDirectory
                ))
            }
        }
        return (remote, members)
    }

    /// Check, ask if there is anything to ask, upload, and report.
    private func runRemoteWriteBacks(_ batch: [PendingWriteBack]) async {
        guard !batch.isEmpty else { return }
        let checked = await checkWriteBacks(batch)
        guard !checked.isEmpty else { return }
        let answer = await writeBackAnswer(for: checked)
        let chosen = WriteBackBatchPlan.items(for: answer, from: checked)
        guard !chosen.isEmpty else { return }
        await uploadWriteBacks(chosen)
    }

    // MARK: - The check

    /// Re-`stat` every destination and pair each with what that found.
    ///
    /// **Sequentially, and that is the ordering the gap was about.** Forty concurrent `stat`s over
    /// SFTP is forty connections at once, which a stock OpenSSH server begins refusing at ten
    /// (`MaxStartups`, docs/NOTES.md ▸ Testing) — and on S3 each one is a billed request whose
    /// answer nobody is waiting on individually. One pass off the cooperative pool costs a round
    /// trip per file and cannot flood anything.
    ///
    /// A status line while it runs, because forty round trips is seconds during which the save the
    /// user pressed ⌘S for has visibly done nothing.
    private func checkWriteBacks(_ batch: [PendingWriteBack]) async -> [CheckedWriteBack] {
        let backend = focusedPanel.backend
        if batch.count > 1 {
            focusedPanel.showTransientStatus(String(
                localized: "Checking \(batch.count) files on the server…",
                comment: "Status while a batch of edited files is checked before being uploaded."
            ))
        }
        let recorded = batch.map { remoteFileCache.revision(for: $0.destination) }
        let destinations = batch.map(\.destination)
        let localPaths = batch.map(\.edit.temporaryURL.path)
        let current: [RemoteFileRevision?] = await BlockingWork.run {
            destinations.map { destination in
                (try? backend.stat(at: destination)).map(RemoteFileRevision.init)
            }
        }
        let sizes: [Int64] = await BlockingWork.run {
            localPaths.map { path in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return zip(batch.indices, batch).map { index, pending in
            CheckedWriteBack(
                edit: pending.edit,
                destination: pending.destination,
                concern: Self.writeBackConcern(
                    recorded: recorded[index], current: current[index]
                ),
                condition: Self.writeCondition(checked: current[index]),
                byteSize: sizes[index]
            )
        }
    }

    // MARK: - The one question

    /// What the user says about this batch — or `.all` with nothing asked, when the checks found
    /// nothing to say.
    ///
    /// The rule the single-save path has followed since 2026-08-23, applied to a set: a check that
    /// answered nothing is not a question, it is the save that was already asked for. Which is the
    /// common case here by construction — the copies were downloaded minutes ago by the same
    /// gesture that rewrote them, so nobody else has touched them.
    private func writeBackAnswer(for checked: [CheckedWriteBack]) async -> WriteBackAnswer {
        guard WriteBackBatchPlan.needsConfirmation(checked) else { return .all }
        return await confirmWriteBacks(checked)
    }

    /// The one sheet, however many files it is about.
    private func confirmWriteBacks(_ checked: [CheckedWriteBack]) async -> WriteBackAnswer {
        let contested = checked.filter(\.hasConcern)
        let alert = NSAlert()
        alert.messageText = Self.writeBackPromptTitle(contested: contested, total: checked.count)
        alert.informativeText = Self.writeBackPromptBody(contested: contested, total: checked.count)
        alert.addButton(withTitle: String(
            localized: "Upload All",
            comment: "Button that uploads every edited file in a batch, contested ones included."
        ))
        // Offered only when there is a clean remainder to upload: with every file contested it
        // would be a button that does exactly what Cancel does, under a name that says otherwise.
        let offersSkip = contested.count < checked.count
        if offersSkip {
            alert.addButton(withTitle: String(
                localized: "Skip Changed Files",
                comment: """
                Button that uploads only the edited files nobody else has touched, leaving the rest \
                for the user to look at.
                """
            ))
        }
        alert.addButton(withTitle: String(
            localized: "Keep Editing",
            comment: """
            Button that declines uploading an edited file, leaving the editor open so the user can \
            save again later.
            """
        ))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which none of these is — so
        // the response, not the title, is what says which one ⎋ means (docs/NOTES.md).
        alert.enableEscapeToCancel(
            safe: offersSkip ? .alertThirdButtonReturn : .alertSecondButtonReturn
        )

        // The watcher raised this, not the user, so a window that has gone away has nobody to ask
        // — and the answer to a question nobody was put is to upload nothing, which leaves every
        // copy watched and asks again on the next save (`sheetAnswer`).
        let response = await alert.sheetAnswer(over: window, whenUnasked: .cancel)
        return Self.answer(for: response, offersSkip: offersSkip)
    }

    /// Which answer a response means. `static` and pure: the mapping is the part worth pinning, and
    /// it changes shape with the button count, which is exactly where an off-by-one lives.
    static func answer(
        for response: NSApplication.ModalResponse,
        offersSkip: Bool
    ) -> WriteBackAnswer {
        switch response {
        case .alertFirstButtonReturn: return .all
        case .alertSecondButtonReturn: return offersSkip ? .clean : .none
        default: return .none
        }
    }

    // MARK: - The upload

    /// Hand the chosen items to the queue and wait for the report.
    ///
    /// Internal rather than private because the *retry* after a refused precondition comes back
    /// through it (`+WriteBackReport`), which is what keeps an unconditional second attempt on the
    /// same bar and the same Stop as the first — and Swift's `private` does not cross files.
    func uploadWriteBacks(_ chosen: [CheckedWriteBack]) async {
        let job = WriteBackBatchPlan.job(for: chosen)
        // Any of the destinations would do — the queue reads it only to decide which volume this
        // job stresses, and a batch spanning two accounts is one job either way.
        let anchor = chosen[0].destination.parent ?? chosen[0].destination
        let report = await withCheckedContinuation { continuation in
            enqueueWriteBack(job, anchor: anchor) { report in
                continuation.resume(returning: report)
            }
        }
        await finishWriteBacks(chosen, report: report)
    }

    /// Queue the job and pair its id with what to do about the report.
    ///
    /// Through `JobDeliveries` rather than by holding the id: `enqueue` is an actor method that
    /// starts the job in the same call, so a batch refused on its first request can finish before
    /// the caller has written down what to do about it (docs/NOTES.md ▸ Swift 6 and concurrency).
    private func enqueueWriteBack(
        _ job: WriteBackJob,
        anchor: VFSPath,
        then: @escaping @MainActor (OperationReport) -> Void
    ) {
        let queue = queue
        let deliveries = writeBackDeliveries
        let operation = FileOperation(
            kind: .writeBack(job),
            sources: [],
            destinationDirectory: anchor
        )
        Task {
            let id = await queue.enqueue(operation, conflictPolicy: .fail)
            deliveries.expect(id, then: then)
        }
    }

    /// Called from the one place a finished job is noticed (`finalizeCompletedJobs`).
    func deliverWriteBackReport(_ report: OperationReport, for id: OperationJobID) {
        writeBackDeliveries.deliver(report, for: id)
    }

    // MARK: - Afterwards

    /// Re-baseline what landed, refresh what is on screen, and say what happened.
    private func finishWriteBacks(
        _ chosen: [CheckedWriteBack],
        report: OperationReport
    ) async {
        let landed = Set(report.writtenBack ?? [])
        let backend = focusedPanel.backend
        for item in chosen where landed.contains(item.destination) {
            // The watch deliberately stays: unlike a repack, an upload changes nothing on this Mac,
            // the editor still has this very file open, and a second save has to come back through
            // here. What must move is the revision the next check compares against — leaving the
            // pre-upload one would have our own write read back as "someone else has edited it",
            // which is the one sentence that must never be wrong.
            await rebaselineWriteBack(item.destination, to: item.edit.temporaryURL, using: backend)
        }
        // An item that was **chosen and not claimed** is one whose remote state nobody knows: a
        // stopped batch can leave a file whose bytes had already gone up, or a truncated one, and
        // the runner cannot tell those apart (measured live — see `RemoteWriteBackLiveTests`).
        // Dropping its recorded revision is what makes the next save say *"Dirnex has no record of
        // what this file looked like"*, which is true, instead of *"someone else has edited it"*,
        // which is a confident answer about our own interrupted write.
        for item in chosen where !landed.contains(item.destination) {
            remoteFileCache.drop(item.destination)
        }
        for directory in Set(landed.compactMap(\.parent)) {
            refreshPanesShowingWriteBack(directory)
        }
        reportWriteBacks(chosen, landed: landed, report: report)
    }

    /// Re-read what the server now holds and record it as the copy's revision.
    ///
    /// A failed read drops the entry instead of keeping the stale one: with nothing recorded the
    /// next save says plainly that it cannot tell, which is true, where a stale revision would say
    /// something false with confidence.
    private func rebaselineWriteBack(
        _ path: VFSPath,
        to url: URL,
        using backend: any VFSBackend
    ) async {
        let uploaded = await BlockingWork.run { try? backend.stat(at: path) }
        guard let uploaded else {
            remoteFileCache.drop(path)
            return
        }
        remoteFileCache.rebaseline(path, to: RemoteFileRevision(uploaded), url: url)
    }

    /// Re-list any pane drawing `directory`, so the size and date it shows are the ones just
    /// written. Both panes, by *content* rather than by role — the pane that opened the file may
    /// have navigated away, and a tree draws several directories at once.
    private func refreshPanesShowingWriteBack(_ directory: VFSPath) {
        for pane in [leftPanel, rightPanel] where pane.isShowing(directory) {
            pane.refreshCurrentDirectory()
        }
    }
}

/// One save on its way back to a server.
typealias PendingWriteBack = (edit: EditedFile, destination: VFSPath)

/// One save on its way back into an archive.
///
/// A struct rather than a tuple because three members trip SwiftLint's `large_tuple` — and because
/// naming them is what keeps the two `String`s from being handed over the wrong way round.
struct PendingArchiveWriteBack: Equatable {
    let edit: EditedFile
    /// The archive on this disk that the member came out of.
    let archivePath: String
    /// The folder *inside* that archive it goes back into — `/` for the root.
    let innerDirectory: String
}
