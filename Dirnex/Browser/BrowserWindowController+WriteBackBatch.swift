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
        await runRemoteWriteBacks(split.remote, over: nil)
        await runArchiveWriteBacks(split.members, over: nil)
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

    /// Check, ask if there is anything to ask, upload, and report. Answers the destinations that
    /// landed, an upload anyway after a refused precondition included.
    ///
    /// `host` is the window the questions go on, or `nil` for this one (`writeBack(_:askingOver:)`).
    @discardableResult
    func runRemoteWriteBacks(_ batch: [PendingWriteBack], over host: NSWindow?) async -> Set<VFSPath> {
        guard !batch.isEmpty else { return [] }
        let checked = await checkWriteBacks(batch)
        guard !checked.isEmpty else { return [] }
        let answer = await writeBackAnswer(for: checked, over: host)
        if answer == .merge, let item = checked.first {
            await mergeWriteBack(item, over: host)
            return []
        }
        let chosen = WriteBackBatchPlan.items(for: answer, from: checked)
        guard !chosen.isEmpty else { return [] }
        return await uploadWriteBacks(chosen, over: host)
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
    ///
    /// Where a `stat` agrees with the record on size and time alone, the server's bytes are compared
    /// with the copy's base (``readServer(at:recorded:bases:check:)``), and a difference is the same
    /// "changed" as a size that moved.
    private func checkWriteBacks(_ batch: [PendingWriteBack]) async -> [CheckedWriteBack] {
        let backend = focusedPanel.backend
        if batch.count > 1 {
            focusedPanel.showTransientStatus(String(
                localized: "Checking \(batch.count) files on the server…",
                comment: "Status while a batch of edited files is checked before being uploaded."
            ))
        }
        let recorded = batch.map { Self.recordedRevision(of: $0, in: remoteFileCache) }
        let bases = batch.map { remoteFileCache.base(ofCopy: $0.edit.temporaryURL) }
        let destinations = batch.map(\.destination)
        let localPaths = batch.map(\.edit.temporaryURL.path)
        let check = WriteBackContentCheck(
            backend: backend,
            previewLimit: AppPreferences.shared.quickViewFetchLimit,
            scratch: RemoteFileCache.checksRoot
        )
        let readings = await BlockingWork.run {
            Self.readServer(at: destinations, recorded: recorded, bases: bases, check: check)
        }
        let sizes: [Int64] = await BlockingWork.run {
            localPaths.map { path in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        // Merge… is offered for a save of one file: a batch's one question is about a set.
        let mergeBase = batch.count == 1
            ? await mergeBase(
                for: batch[0],
                recorded: recorded[0],
                current: readings[0].entry,
                contentChanged: readings[0].content.isChange
            )
            : nil
        return Self.checkedWriteBacks(
            batch, recorded: recorded, readings: readings, sizes: sizes, mergeBase: mergeBase
        )
    }

    /// Each save of `batch` paired with what its check found: the concern the prompt names, and the
    /// precondition the upload carries, read off the server's file as the check found it. `static`
    /// and pure so what a reading turns into is assertable with no window.
    static func checkedWriteBacks(
        _ batch: [PendingWriteBack],
        recorded: [RemoteFileRevision?],
        readings: [WriteBackServerReading],
        sizes: [Int64],
        mergeBase: URL?
    ) -> [CheckedWriteBack] {
        zip(batch.indices, batch).map { index, pending in
            let current = readings[index].entry.map(RemoteFileRevision.init)
            return CheckedWriteBack(
                edit: pending.edit,
                destination: pending.destination,
                concern: writeBackConcern(
                    recorded: recorded[index],
                    current: current,
                    contentChanged: readings[index].content.isChange
                ),
                condition: writeCondition(checked: current),
                byteSize: sizes[index],
                mergeBase: mergeBase
            )
        }
    }

    /// What the server holds at each destination: its re-`stat`, and what its bytes say against the
    /// copy's base where that `stat` agrees with `recorded` on size and time alone.
    ///
    /// Over SFTP the time is a minute, so a same-size write in the minute of the last upload agrees,
    /// and the next save went over it with no question until the bytes were asked (seen live
    /// 2026-10-27, docs/NOTES.md ▸ sftp). One file after another, as the `stat`s always were.
    /// Blocking; call it off the main thread. `static` so the wiring is assertable with no window.
    nonisolated static func readServer(
        at destinations: [VFSPath],
        recorded: [RemoteFileRevision?],
        bases: [URL?],
        check: WriteBackContentCheck
    ) -> [WriteBackServerReading] {
        destinations.indices.map { index in
            let entry = try? check.backend.stat(at: destinations[index])
            return WriteBackServerReading(
                entry: entry,
                content: check.verdict(recorded: recorded[index], current: entry, base: bases[index])
            )
        }
    }

    /// The revision a save of `pending` is checked against: the one **its copy** was downloaded at,
    /// or last uploaded at, and never the newest fetch of the path.
    ///
    /// A path can have two copies, an edit's and a newer one a preview brought down after the server
    /// changed. Read by path, the edit's save was checked against the newer revision, found nothing,
    /// and uploaded the older bytes over the change with no question (M21 Slice 10 to 2026-10-25).
    /// `static` so the choice is assertable with no window.
    static func recordedRevision(
        of pending: PendingWriteBack,
        in cache: RemoteFileCache
    ) -> RemoteFileRevision? {
        cache.revision(ofCopy: pending.edit.temporaryURL)
    }

    // MARK: - The one question

    /// What the user says about this batch — or `.all` with nothing asked, when the checks found
    /// nothing to say.
    ///
    /// The rule the single-save path has followed since 2026-08-23, applied to a set: a check that
    /// answered nothing is not a question, it is the save that was already asked for. Which is the
    /// common case here by construction — the copies were downloaded minutes ago by the same
    /// gesture that rewrote them, so nobody else has touched them.
    private func writeBackAnswer(
        for checked: [CheckedWriteBack],
        over host: NSWindow?
    ) async -> WriteBackAnswer {
        guard WriteBackBatchPlan.needsConfirmation(checked) else { return .all }
        return await confirmWriteBacks(checked, over: host)
    }

    /// The one sheet, however many files it is about.
    private func confirmWriteBacks(
        _ checked: [CheckedWriteBack],
        over host: NSWindow?
    ) async -> WriteBackAnswer {
        let contested = checked.filter(\.hasConcern)
        // Skip is offered only when there is a clean remainder to upload: with every file contested
        // it would be a button that does exactly what Cancel does, under a name that says otherwise.
        let offersSkip = contested.count < checked.count
        let offersMerge = checked.count == 1 && checked[0].mergeBase != nil
        let alert = NSAlert()
        alert.messageText = Self.writeBackPromptTitle(contested: contested, total: checked.count)
        let body = Self.writeBackPromptBody(contested: contested, total: checked.count)
        alert.informativeText = offersMerge ? Self.mergeOfferBody(body) : body
        let answers = Self.promptAnswers(offersSkip: offersSkip, offersMerge: offersMerge)
        for answer in answers {
            alert.addButton(withTitle: Self.buttonTitle(for: answer, files: checked.count))
        }
        // `NSAlert` binds Escape by matching the byte string "Cancel", which none of these is — so
        // the response, not the title, is what says which one ⎋ means (docs/NOTES.md).
        alert.enableEscapeToCancel(safe: Self.response(for: .none, in: answers))

        // The watcher raised this, not the user, so a window that has gone away has nobody to ask
        // — and the answer to a question nobody was put is to upload nothing, which leaves every
        // copy watched and asks again on the next save (`sheetAnswer`).
        let response = await alert.sheetAnswer(over: host ?? window, whenUnasked: .cancel)
        return Self.answer(for: response, offersSkip: offersSkip, offersMerge: offersMerge)
    }

    /// The prompt's buttons in the order it draws them. Merge… comes first where it is offered, so
    /// Return takes the one answer that loses nobody's edit; Keep Editing is always last.
    static func promptAnswers(offersSkip: Bool, offersMerge: Bool) -> [WriteBackAnswer] {
        (offersMerge ? [.merge] : []) + [.all] + (offersSkip ? [.clean] : []) + [.none]
    }

    /// Which answer a response means. `static` and pure: the mapping is the part worth pinning, and
    /// it changes shape with the button count, which is exactly where an off-by-one lives.
    static func answer(
        for response: NSApplication.ModalResponse,
        offersSkip: Bool,
        offersMerge: Bool = false
    ) -> WriteBackAnswer {
        answer(for: response, among: promptAnswers(offersSkip: offersSkip, offersMerge: offersMerge))
    }

    /// Which of `answers`, drawn as buttons in that order, a response means. Anything else is
    /// Keep Editing's: a sheet nobody answered uploads nothing.
    static func answer(
        for response: NSApplication.ModalResponse,
        among answers: [WriteBackAnswer]
    ) -> WriteBackAnswer {
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) ? answers[index] : .none
    }

    /// The response the button for `answer` gives, in a prompt drawing `answers`.
    static func response(
        for answer: WriteBackAnswer,
        in answers: [WriteBackAnswer]
    ) -> NSApplication.ModalResponse {
        let index = answers.firstIndex(of: answer) ?? answers.count - 1
        return NSApplication.ModalResponse(
            NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
        )
    }

    /// Each answer's button, in a prompt about `files` files. One file is uploaded, not all of it.
    static func buttonTitle(for answer: WriteBackAnswer, files: Int) -> String {
        switch answer {
        case .merge:
            mergeButtonTitle
        case .all where files == 1:
            String(
                localized: "Upload",
                comment: "Button that uploads an edited file back to the server it came from."
            )
        case .all:
            String(
                localized: "Upload All",
                comment: "Button that uploads every edited file in a batch, contested ones included."
            )
        case .clean:
            String(
                localized: "Skip Changed Files",
                comment: """
                Button that uploads only the edited files nobody else has touched, leaving the rest \
                for the user to look at.
                """
            )
        case .none:
            String(
                localized: "Keep Editing",
                comment: """
                Button that declines uploading an edited file, leaving the editor open so the user \
                can save again later.
                """
            )
        }
    }

    // MARK: - The upload

    /// Hand the chosen items to the queue, wait for the report, and answer the destinations that
    /// landed.
    ///
    /// Internal rather than private because the *retry* after a refused precondition comes back
    /// through it (`+WriteBackReport`), which is what keeps an unconditional second attempt on the
    /// same bar and the same Stop as the first — and Swift's `private` does not cross files.
    func uploadWriteBacks(_ chosen: [CheckedWriteBack], over host: NSWindow?) async -> Set<VFSPath> {
        let chosen = await withSentDuplicates(chosen)
        let job = WriteBackBatchPlan.job(for: chosen)
        // Any of the destinations would do — the queue reads it only to decide which volume this
        // job stresses, and a batch spanning two accounts is one job either way.
        let anchor = chosen[0].destination.parent ?? chosen[0].destination
        let report = await withCheckedContinuation { continuation in
            enqueueWriteBack(job, anchor: anchor) { report in
                continuation.resume(returning: report)
            }
        }
        return await finishWriteBacks(chosen, report: report, over: host)
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

    /// Re-baseline what landed, refresh what is on screen, say what happened, and answer what
    /// landed, now or by an upload anyway the report offered.
    private func finishWriteBacks(
        _ chosen: [CheckedWriteBack],
        report: OperationReport,
        over host: NSWindow?
    ) async -> Set<VFSPath> {
        let landed = Set(report.writtenBack ?? [])
        let backend = focusedPanel.backend
        for item in chosen where landed.contains(item.destination) {
            // The watch deliberately stays: unlike a repack, an upload changes nothing on this Mac,
            // the editor still has this very file open, and a second save has to come back through
            // here. What must move is the revision the next check compares against — leaving the
            // pre-upload one would have our own write read back as "someone else has edited it",
            // which is the one sentence that must never be wrong.
            await rebaselineWriteBack(item, using: backend)
        }
        // An item that was **chosen and not claimed** is one whose remote state nobody knows: a
        // stopped batch can leave a file whose bytes had already gone up, or a truncated one, and
        // the runner cannot tell those apart (measured live — see `RemoteWriteBackLiveTests`).
        // Dropping its recorded revision is what makes the next save say *"Dirnex has no record of
        // what this file looked like"*, which is true, instead of *"someone else has edited it"*,
        // which is a confident answer about our own interrupted write.
        //
        // Except where the server refused the precondition: it wrote nothing, so the record and the
        // base still say what the copy came from, and Merge… can be offered (PLAN.md §M34 Slice 4).
        let refused = Set(report.failures.compactMap { failure in
            Self.writeBackConflict(from: failure.error) == nil ? nil : failure.path
        })
        for item in chosen where !landed.contains(item.destination) {
            if let sent = item.sent { remoteFileCache.baseStore.discard(sent) }
            guard !refused.contains(item.destination) else { continue }
            remoteFileCache.forget(copy: item.edit.temporaryURL)
        }
        for directory in Set(landed.compactMap(\.parent)) {
            refreshPanesShowingWriteBack(directory)
        }
        let retried = await reportWriteBacks(chosen, landed: landed, report: report, over: host)
        return landed.union(retried)
    }

    /// Re-read what the server now holds and record it as the copy's revision, with the duplicate
    /// the upload sent as its base.
    ///
    /// A failed read forgets the copy's record instead of keeping the stale one: with nothing
    /// recorded the next save says plainly that it cannot tell, which is true, where a stale
    /// revision would say something false with confidence.
    private func rebaselineWriteBack(_ item: CheckedWriteBack, using backend: any VFSBackend) async {
        let path = item.destination
        let url = item.edit.temporaryURL
        let uploaded = await BlockingWork.run { try? backend.stat(at: path) }
        guard let uploaded else {
            remoteFileCache.forget(copy: url)
            if let sent = item.sent { remoteFileCache.baseStore.discard(sent) }
            return
        }
        remoteFileCache.rebaseline(path, to: RemoteFileRevision(uploaded), url: url, sent: item.sent)
    }

    /// `chosen`, each carrying a duplicate of its copy taken now for the upload to send. Off the
    /// main thread, since a copy that cannot be cloned is copied. An item whose duplicate could not
    /// be taken sends the copy itself, and keeps no base once it lands.
    private func withSentDuplicates(_ chosen: [CheckedWriteBack]) async -> [CheckedWriteBack] {
        let store = remoteFileCache.baseStore
        let copies = chosen.map(\.edit.temporaryURL)
        let sent = await BlockingWork.run { copies.map { store.keep($0) } }
        return zip(chosen, sent).map { item, duplicate in
            var item = item
            item.sent = duplicate
            return item
        }
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
