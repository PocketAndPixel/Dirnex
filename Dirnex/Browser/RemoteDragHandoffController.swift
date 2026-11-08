import AppKit
import DirnexCore

/// One drag of rows whose bytes are on a server, while it is under way: what lets such a row drop into
/// Teams, Slack, Chrome and everything else that only takes a real file. Since M36 Slice 2 a file
/// inside an archive is one of those rows too, **extracted** where a server's file is downloaded, and
/// since 2026-11-08 a **folder**, here or on a server, is made into a zip, because those apps take a
/// file and fail on a folder (`DragOutZip`).
///
/// `RemoteDragHandoff` holds the rules and says why each is there. This object does what they ask:
/// it watches which app is under the pointer, rewrites the drag's board, brings the bytes down and
/// answers the reads. A drop into Finder before any other app was crossed never involves it, because
/// Finder takes the promise or the URL the drag started with. After a crossing, a drag holding a
/// folder writes Finder a board of its own, with the folder rather than its zip.
///
/// **The bytes land in the cache and do not go through the queue.** A queued job is something the user
/// asked for, reported per item with a Stop button in a window they have left, and this is something
/// the pointer did on its way across the screen. So a row already fetched for a preview costs nothing
/// here, and what this brings down serves the next preview and the next drag. A zip serves nobody
/// after the drag, so it is never left to finish unasked, and what the drop did not use is removed.
///
/// **The transfer needs nothing from the main thread until it is over**, because a held read is
/// sitting on that thread waiting for it. It runs off the main actor and leaves its outcome in a box
/// the hold looks at. The first version kept the run loop turning during a hold and awaited
/// `RemoteFileCache.fetch`, whose last step is on the main actor: a run loop nested inside a main-queue
/// job does not drain the main queue, so the read could wait the whole limit on a transfer that had
/// finished. Turning the run loop bought nothing anyway, since the drag does not move during a read.
@MainActor
final class RemoteDragHandoffController {
    private var handoff: RemoteDragHandoff
    /// The drag session's own board.
    private let board: NSPasteboard
    /// Every row of the drag, in order, including any a file URL cannot stand for (a folder inside an
    /// archive, a row of a locked archive), which the board keeps carrying on its payload alone.
    let entries: [FileEntry]
    private let cache: RemoteFileCache
    private let backend: any VFSBackend
    private let holdLimit: Duration
    /// Who is under the pointer. Injected because a test has no pointer to move.
    private let surfaceUnderPointer: @MainActor () -> RemoteDragHandoff.Surface
    private let showStatus: (String?) -> Void
    private let onLanded: () -> Void
    private let onFailure: (any Error) -> Void
    /// What each row offers another app, and what extracting a member needs.
    private let offer: DragOutOffer
    /// What writes a folder's zip: ⌥F5's `bsdtar` packer, injected so a test can watch it.
    private let zipWriter: any PlainPackWriting
    /// Whether the drag has been over another app yet, so a locked row is mentioned once.
    private var hasLeftDirnex = false

    /// What each row is handed to an app other than Finder as: a copy brought down, a member
    /// extracted, or a folder's zip.
    private var files: [VFSPath: URL] = [:]
    /// What Finder is handed where that differs: a server folder's staged tree rather than its zip.
    private var finderFiles: [VFSPath: URL] = [:]
    /// The zips and staged trees this drag made, which the drag's end sorts into kept and removed.
    private var zipped: [DragOutZip.Made] = []
    /// Written by the transfer's own thread and read when the status is drawn.
    private let moved = ByteCounter()
    private let phase = RemoteDragPhaseBox(.downloading)
    private let cancellation = CancellationFlag()
    private let outcome = RemoteDragTransferOutcome()
    /// Kept here because a pasteboard item does not promise to keep its data provider alive.
    private var providers: [FileURLProvider] = []
    private var isDragging = true
    private var failure: (any Error)?
    private var statusTask: Task<Void, Never>?

    /// Whether bytes are still on their way, which is what the end of the drag has to decide about.
    var isTransferring: Bool {
        handoff.transfer == .running
    }

    /// Whether the drag makes a zip, which is never left to finish after it: nothing keeps one for a
    /// second try, so finishing would only spend the time and the disk.
    var makesZips: Bool {
        remoteRows.contains { offer.routes[$0.path]?.zipsForOtherApps == true }
    }

    /// The rows of `entries` this has to bring down, extract or zip.
    private var remoteRows: [FileEntry] {
        entries.filter { offer.routes[$0.path]?.isHandedOff == true }
    }

    /// The rows the board offers through this object to whoever it is written for: every one for
    /// other apps, and for Finder all but a folder on this disk, which Finder takes by its own URL.
    private var rowsForAudience: [FileEntry] {
        guard handoff.audience == .finder else { return remoteRows }
        return remoteRows.filter { offer.routes[$0.path] != .folderURL }
    }

    init(
        board: NSPasteboard,
        entries: [FileEntry],
        cache: RemoteFileCache,
        backend: any VFSBackend,
        holdLimit: Duration = RemoteDragHandoff.holdLimit,
        surfaceUnderPointer: @escaping @MainActor () -> RemoteDragHandoff.Surface = RemoteDragPointer.surface,
        showStatus: @escaping (String?) -> Void,
        onLanded: @escaping () -> Void,
        onFailure: @escaping (any Error) -> Void,
        offer: DragOutOffer? = nil,
        zipWriter: any PlainPackWriting = ArchivePacker()
    ) {
        let offer = offer ?? .serverFilesOnly(entries, cache: cache)
        self.offer = offer
        handoff = RemoteDragHandoff(finderHasItsOwnBoard: offer.finderHasItsOwnBoard)
        self.board = board
        self.entries = entries
        self.cache = cache
        self.backend = backend
        self.holdLimit = holdLimit
        self.surfaceUnderPointer = surfaceUnderPointer
        self.showStatus = showStatus
        self.onLanded = onLanded
        self.onFailure = onFailure
        self.zipWriter = zipWriter
    }

    // MARK: - The drag

    /// The pointer moved. Has to be cheap and has to be prompt: the app under it reads the board a few
    /// milliseconds after this returns.
    func pointerMoved() {
        let surface = surfaceUnderPointer()
        if surface != .neutral, !hasLeftDirnex {
            hasLeftDirnex = true
            if offer.holdsLockedRows { offer.onLockedRowsLeaving() }
        }
        apply(handoff.pointerMoved(over: surface))
    }

    /// The drag is over, whichever way. `mayFinish` is whether a transfer still running may carry on
    /// with nobody watching, which a zip never may. `operation` is what the drop came to, which with
    /// where the pointer let go says which of the drag's zips and staged trees anybody took.
    func dragEnded(mayFinish: Bool, operation: NSDragOperation = []) {
        isDragging = false
        statusTask?.cancel()
        apply(handoff.dragEnded(mayFinish: mayFinish && !makesZips))
        zipped.sweep(droppedOn: operation.isEmpty ? nil : surfaceUnderPointer())
        zipped = []
        if let failure { onFailure(failure) }
        failure = nil
    }

    // MARK: - Answering a read

    /// What to tell an app asking for `entry`'s file URL, holding the read while the bytes are close.
    fileprivate func fileURLString(for entry: FileEntry) -> String? {
        let surface = surfaceUnderPointer()
        settleTransfer()
        var answer = handoff.readFileURL(from: surface)
        if answer == .wait {
            hold(over: surface)
            answer = handoff.readFileURL(from: surface)
        }
        guard answer == .fileURLs else { return nil }
        return handedFile(for: entry)?.absoluteString
    }

    /// The file the board's current audience is handed for `entry`.
    private func handedFile(for entry: FileEntry) -> URL? {
        if handoff.audience == .finder, let staged = finderFiles[entry.path] { return staged }
        return files[entry.path]
    }

    /// Keep the app waiting until the bytes land, the limit runs out, or the pointer moves on from it.
    ///
    /// Blocks the main thread on purpose, and only for ``RemoteDragHandoff/holdLimit``: nothing else
    /// can usefully happen, since the drag does not move during a read whatever this thread does.
    private func hold(over surface: RemoteDragHandoff.Surface) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: holdLimit)
        while !outcome.isSettled, isDragging, clock.now < deadline, surfaceUnderPointer() == surface {
            usleep(10000)
        }
        settleTransfer()
        handoff.holdEnded(over: surface)
    }

    // MARK: - Doing what the rules ask

    private func apply(_ effects: [RemoteDragHandoff.Effect]) {
        for effect in effects {
            switch effect {
            case .writeLazyFileURLs:
                providers = rowsForAudience.map { FileURLProvider(entry: $0, owner: self) }
                let byPath = Dictionary(
                    providers.map { ($0.entry.path, $0) }, uniquingKeysWith: { first, _ in first }
                )
                write(PanelPasteboard.handoffItems(for: entries) { entry in
                    byPath[entry.path].map { .answeredWhenRead($0) }
                })
            case .writeFileURLs:
                let offered = Set(rowsForAudience.map(\.path))
                write(PanelPasteboard.handoffItems(for: entries) { entry in
                    guard offered.contains(entry.path) else { return nil }
                    return self.handedFile(for: entry).map { .here($0) }
                })
            case .startTransfer:
                startTransfer()
            case .stopTransfer:
                cancellation.isCancelled = true
            }
        }
    }

    private func write(_ items: [NSPasteboardItem]) {
        board.clearContents()
        board.writeObjects(items)
    }

    private func startTransfer() {
        let rows = remoteRows
        for row in rows where offer.routes[row.path]?.zipsForOtherApps != true {
            // A folder is never "already here" as a zip: `alreadyHere` answers a folder on this disk
            // with the folder itself, which is exactly what another app cannot take.
            if let held = offer.alreadyHere(row) { files[row.path] = held }
        }
        let missing = rows.filter { files[$0.path] == nil }
        guard !missing.isEmpty else {
            landed()
            return
        }
        // Two transfers of the row the cursor is on would otherwise race for one object.
        cache.cancelAutomaticFetch()
        phase.value = RemoteDragTransfer.phase(startingWith: missing[0], routes: offer.routes)
        followProgress(ofBytes: missing.map(\.byteSize))
        runTransfer(of: missing)
    }

    /// Bring `rows` down on a thread of their own, and come back to the main actor once they are done.
    private func runTransfer(of rows: [FileEntry]) {
        let transfer = RemoteDragTransfer(
            rows: rows,
            extractions: offer.extractions,
            zips: Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard offer.routes[row.path]?.zipsForOtherApps == true else { return nil }
                return (row.path, DragOutZip(
                    row: row, root: RemoteFileCache.temporaryRoot, backend: backend,
                    writer: zipWriter
                ))
            }),
            backend: backend,
            moved: moved,
            phase: phase,
            cancellation: cancellation
        )
        let outcome = outcome
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.settle(transfer.run())
            Task { @MainActor [self] in settleTransfer() }
        }
    }

    /// Take in whatever the transfer has finished with, once. Asked by a read as well as by the
    /// transfer itself, because a read on the main thread gets here before the transfer's own hop can.
    private func settleTransfer() {
        guard handoff.transfer == .running, let settled = outcome.settled else { return }
        // Whatever did land stays useful, even if a later row of the set failed.
        cache.adopt(settled.landed)
        for file in settled.landed {
            files[file.source] = URL(fileURLWithPath: file.localPath)
        }
        files.merge(settled.extracted) { _, extracted in extracted }
        for made in settled.zipped {
            files[made.source] = made.zip
            if let staged = made.staged { finderFiles[made.source] = staged }
        }
        zipped = settled.zipped
        statusTask?.cancel()
        guard let error = settled.error else {
            landed()
            return
        }
        handoff.transferFailed()
        // Being called off is not a failure, and after the drag there is nobody left to tell.
        guard !(error is CancellationError) else { return }
        if isDragging { failure = error }
        drawStatus()
    }

    private func landed() {
        apply(handoff.transferLanded())
        statusTask?.cancel()
        drawStatus()
        // Not from inside a read, which may be what got here, and which another app is waiting on.
        let onLanded = onLanded
        Task { @MainActor in onLanded() }
    }

    // MARK: - Saying how it is going

    /// Keep the drag image's status current for as long as the transfer runs. Polled, for the reason
    /// `RemoteFetchPrompt` polls: a transfer reports far more often than anybody can read.
    private func followProgress(ofBytes sizes: [Int64]) {
        let total = sizes.allSatisfy { $0 >= 0 } ? sizes.reduce(0, +) : nil
        statusTask = Task { [weak self] in
            while !Task.isCancelled, let self, handoff.transfer == .running {
                drawStatus(total: total)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func drawStatus(total: Int64? = nil) {
        guard isDragging else { return }
        switch handoff.transfer {
        case .notStarted:
            showStatus(nil)
        case .running:
            switch phase.value {
            case .extracting: showStatus(RemoteDragStatus.extracting)
            case .compressing: showStatus(RemoteDragStatus.compressing)
            case .downloading: showStatus(
                    RemoteDragStatus.downloading(moved: moved.value, of: total)
                )
            }
        case .landed:
            // Worth saying only to an app that was already told there was nothing, because it will
            // not look again until the pointer leaves it and comes back.
            showStatus(handoff.board == .fileURLs ? RemoteDragStatus.ready : nil)
        case .failed:
            switch phase.value {
            case .extracting: showStatus(RemoteDragStatus.extractionFailed)
            case .compressing: showStatus(RemoteDragStatus.compressionFailed)
            case .downloading: showStatus(RemoteDragStatus.failed)
            }
        }
    }
}

/// Answers an app reading one row's `public.file-url`.
@MainActor
private final class FileURLProvider: NSObject, NSPasteboardItemDataProvider {
    let entry: FileEntry
    private weak var owner: RemoteDragHandoffController?

    init(entry: FileEntry, owner: RemoteDragHandoffController) {
        self.entry = entry
        self.owner = owner
    }

    /// Always on the main thread when measured, the promise's own delegate being the same, and written
    /// so as not to depend on it. Whatever comes back, the read gets no second chance.
    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        let answer: String? = if Thread.isMainThread {
            MainActor.assumeIsolated { answerRead() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { answerRead() } }
        }
        if let answer { item.setString(answer, forType: type) }
    }

    private func answerRead() -> String? {
        owner?.fileURLString(for: entry)
    }

    nonisolated func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}
}
