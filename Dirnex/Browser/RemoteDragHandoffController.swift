import AppKit
import DirnexCore

/// One drag of rows whose bytes are on a server, while it is under way: what lets such a row drop into
/// Teams, Slack, Chrome and everything else that only takes a real file. Since M36 Slice 2 a file
/// inside an archive is one of those rows too, **extracted** where a server's file is downloaded, and
/// since 2026-11-08 a **folder**, here or on a server, which since 2026-11-09 goes as itself and is
/// made into a zip for an app the pointer enters with Shift held (`DragOutZip`).
///
/// `RemoteDragHandoff` holds the rules and says why each is there. This object does what they ask:
/// it watches which app is under the pointer and whether Shift is down, rewrites the drag's board,
/// brings the bytes down, makes the zips and answers the reads. A drop into Finder before any other
/// app was crossed never involves it, because Finder takes the promise or the URL the drag started
/// with, and neither does a folder on this disk, until Shift asks for a zip.
///
/// **The bytes land in the cache and do not go through the queue.** A queued job is something the user
/// asked for, reported per item with a Stop button in a window they have left, and this is something
/// the pointer did on its way across the screen. So a row already fetched for a preview costs nothing
/// here, and what this brings down serves the next preview and the next drag. A staged tree or a zip
/// serves nobody after the drag, so neither is left to finish unasked, and what the drop did not use
/// is removed.
///
/// **The transfer needs nothing from the main thread until it is over**, because a held read is
/// sitting on that thread waiting for it. It runs off the main actor and leaves its outcome in a box
/// the hold looks at. The first version kept the run loop turning during a hold and awaited
/// `RemoteFileCache.fetch`, whose last step is on the main actor: a run loop nested inside a main-queue
/// job does not drain the main queue, so the read could wait the whole limit on a transfer that had
/// finished. Turning the run loop bought nothing anyway, since the drag does not move during a read.
@MainActor
final class RemoteDragHandoffController {
    private(set) var handoff: RemoteDragHandoff
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
    /// Whether Shift is down. Injected because a test has no keyboard.
    let shiftHeld: @MainActor () -> Bool
    let showStatus: (String?) -> Void
    private let onLanded: () -> Void
    private let onFailure: (any Error) -> Void
    /// What each row offers another app, and what extracting a member needs.
    let offer: DragOutOffer
    /// What writes a folder's zip: ⌥F5's `bsdtar` packer, injected so a test can watch it.
    private let zipWriter: any PlainPackWriting
    /// Whether the drag has been over another app yet, so a locked row is mentioned once.
    private var hasLeftDirnex = false
    /// Where the pointer was last, which the status line depends on.
    private(set) var lastSurface: RemoteDragHandoff.Surface = .neutral
    /// Notices Shift changing with the pointer still, which the drag never reports, to redraw the line.
    private var shiftWatch: DragShiftWatch?

    /// What each row is handed as itself: a copy brought down, a member extracted, or a server's
    /// folder staged. A folder on this disk is not here: it goes by its own URL.
    private var files: [VFSPath: URL] = [:]
    /// Each folder's zip, handed over in its place while Shift is held.
    private var zips: [VFSPath: URL] = [:]
    /// What this drag left under the temp root, which its end sorts into kept and removed.
    private var stagedTrees: [URL] = []
    private var madeZips: [URL] = []
    /// Written by the transfer's own thread and read when the status is drawn.
    let moved = ByteCounter()
    let phase = RemoteDragPhaseBox(.downloading)
    private let cancellation = CancellationFlag()
    private let outcome = RemoteDragTransferOutcome()
    private let compressionOutcome = DragOutCompressionOutcome()
    /// Kept here because a pasteboard item does not promise to keep its data provider alive.
    private var providers: [FileURLProvider] = []
    private(set) var isDragging = true
    private var failure: (any Error)?
    /// A zip that could not be made, reported only if the drag ended still asking for zips.
    private var zipFailure: (any Error)?
    var statusTask: Task<Void, Never>?
    /// How many bytes the transfer brings down in all, when every row's size is known.
    var progressTotal: Int64?

    /// Whether bytes are still on their way, which is what the end of the drag has to decide about.
    var isTransferring: Bool {
        handoff.transfer == .running
    }

    /// Whether the transfer stages a server's folder, which is never left to finish after the drag:
    /// nothing keeps a staged tree for a second try, so finishing would only spend the time and the disk.
    var stagesFolders: Bool {
        offer.routes.values.contains(.downloadFolder)
    }

    /// The rows of `entries` this may have to bring down, extract, stage or zip.
    private var handedOffRows: [FileEntry] {
        entries.filter { offer.routes[$0.path]?.isHandedOff == true }
    }

    /// The rows the board offers through this object in its current form: all of them while it offers
    /// zips, and otherwise all but a folder on this disk, which goes by its own URL.
    private var rowsOnBoard: [FileEntry] {
        guard handoff.form == .folders else { return handedOffRows }
        return handedOffRows.filter { offer.routes[$0.path] != .folderURL }
    }

    init(
        board: NSPasteboard,
        entries: [FileEntry],
        cache: RemoteFileCache,
        backend: any VFSBackend,
        holdLimit: Duration = RemoteDragHandoff.holdLimit,
        surfaceUnderPointer: @escaping @MainActor () -> RemoteDragHandoff.Surface = RemoteDragPointer.surface,
        shiftHeld: @escaping @MainActor () -> Bool = { NSEvent.modifierFlags.contains(.shift) },
        showStatus: @escaping (String?) -> Void,
        onLanded: @escaping () -> Void,
        onFailure: @escaping (any Error) -> Void,
        offer: DragOutOffer? = nil,
        zipWriter: any PlainPackWriting = ArchivePacker()
    ) {
        let offer = offer ?? .serverFilesOnly(entries, cache: cache)
        self.offer = offer
        handoff = RemoteDragHandoff(
            holdsFolders: offer.holdsFolders, beganWithPromises: offer.beganWithPromises
        )
        self.board = board
        self.entries = entries
        self.cache = cache
        self.backend = backend
        self.holdLimit = holdLimit
        self.surfaceUnderPointer = surfaceUnderPointer
        self.shiftHeld = shiftHeld
        self.showStatus = showStatus
        self.onLanded = onLanded
        self.onFailure = onFailure
        self.zipWriter = zipWriter
        if offer.holdsFolders {
            shiftWatch = DragShiftWatch(keyHeld: shiftHeld) { [weak self] in self?.drawStatus() }
        }
    }

    // MARK: - The drag

    /// The pointer moved. Has to be cheap and has to be prompt: the app under it reads the board a few
    /// milliseconds after this returns.
    func pointerMoved() {
        let surface = surfaceUnderPointer()
        lastSurface = surface
        if surface != .neutral, !hasLeftDirnex {
            hasLeftDirnex = true
            if offer.holdsLockedRows { offer.onLockedRowsLeaving() }
        }
        apply(handoff.pointerMoved(over: surface, shiftHeld: shiftHeld()))
        drawStatus()
    }

    /// The drag is over, whichever way. `mayFinish` is whether a transfer still running may carry on
    /// with nobody watching, which a staging never may. `operation` is what the drop came to, which
    /// with where the pointer let go says whether anybody took the drag's zips or staged trees.
    func dragEnded(mayFinish: Bool, operation: NSDragOperation = []) {
        isDragging = false
        statusTask?.cancel()
        apply(handoff.dragEnded(mayFinish: mayFinish && !stagesFolders))
        // What the board was written as when the pointer entered the app it let go over, which is what
        // that app took.
        let taken = operation.isEmpty || surfaceUnderPointer() == .neutral ? nil : handoff.form
        RemoteDragArtifacts.sweep(zips: madeZips, stagedTrees: stagedTrees, taken: taken)
        madeZips = []
        stagedTrees = []
        shiftWatch?.stop()
        shiftWatch = nil
        if let failure {
            onFailure(failure)
        } else if let zipFailure, handoff.form == .zips {
            onFailure(zipFailure)
        }
        failure = nil
        zipFailure = nil
    }

    // MARK: - Doing what the rules ask

    private func apply(_ effects: [RemoteDragHandoff.Effect]) {
        for effect in effects {
            switch effect {
            case .writeLazyFileURLs:
                providers = rowsOnBoard.map { FileURLProvider(entry: $0, owner: self) }
                let byPath = Dictionary(
                    providers.map { ($0.entry.path, $0) }, uniquingKeysWith: { first, _ in first }
                )
                write(PanelPasteboard.handoffItems(for: entries) { entry in
                    byPath[entry.path].map { .answeredWhenRead($0) }
                })
            case .writeFileURLs:
                let offered = Set(rowsOnBoard.map(\.path))
                write(PanelPasteboard.handoffItems(for: entries) { entry in
                    guard offered.contains(entry.path) else { return nil }
                    return self.handedFile(for: entry).map { .here($0) }
                })
            case .startTransfer:
                startTransfer()
            case .startCompression:
                startCompression()
            case .stopTransfer:
                cancellation.isCancelled = true
            }
        }
    }

    private func write(_ items: [NSPasteboardItem]) {
        board.clearContents()
        board.writeObjects(items)
    }
}

// MARK: - Answering a read

extension RemoteDragHandoffController {
    /// What to tell an app asking for `entry`'s file URL, holding the read while the bytes are close.
    fileprivate func fileURLString(for entry: FileEntry) -> String? {
        let surface = surfaceUnderPointer()
        settleTransfer()
        settleCompression()
        var answer = handoff.readFileURL(from: surface)
        if answer == .wait {
            hold(over: surface)
            answer = handoff.readFileURL(from: surface)
        }
        guard answer == .fileURLs else { return nil }
        return handedFile(for: entry)?.absoluteString
    }

    /// The file the board's current form hands over for `entry`.
    private func handedFile(for entry: FileEntry) -> URL? {
        if handoff.form == .zips, offer.routes[entry.path]?.zipsWithShift == true {
            return zips[entry.path]
        }
        return files[entry.path]
    }

    /// Keep the app waiting until what it reads is made, the limit runs out, or the pointer moves on.
    ///
    /// Blocks the main thread on purpose, and only for ``RemoteDragHandoff/holdLimit``: nothing else
    /// can usefully happen, since the drag does not move during a read whatever this thread does.
    /// Settles as it goes, because a zip starts only once the transfer it is made from is taken in.
    private func hold(over surface: RemoteDragHandoff.Surface) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: holdLimit)
        while isDragging, clock.now < deadline, surfaceUnderPointer() == surface {
            settleTransfer()
            settleCompression()
            guard handoff.progress == .running else { break }
            usleep(10000)
        }
        settleTransfer()
        settleCompression()
        handoff.holdEnded(over: surface)
    }
}

// MARK: - Bringing the bytes down, and zipping them

extension RemoteDragHandoffController {
    private func startTransfer() {
        let rows = handedOffRows.filter { offer.routes[$0.path]?.isPromised == true }
        for row in rows where row.kind != .directory {
            // A folder is never "already here": nothing keeps a staged tree from one drag to the next.
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
        files.merge(settled.staged) { _, staged in staged }
        stagedTrees += settled.staged.values
        if !isDragging {
            // Finished as the drag ended, after its sweep: nobody can take these now.
            RemoteDragArtifacts.sweep(zips: [], stagedTrees: stagedTrees, taken: nil)
            stagedTrees = []
        }
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

    /// Zip every folder on a thread of its own: a folder on this disk from itself, and a server's from
    /// the tree the transfer staged.
    private func startCompression() {
        let jobs = handedOffRows.compactMap { row -> DragOutZip? in
            guard offer.routes[row.path]?.zipsWithShift == true else { return nil }
            let folder = row.path.backend == .local ? row.path.localURL : files[row.path]
            return folder.map {
                DragOutZip(
                    row: row,
                    folder: $0,
                    root: RemoteFileCache.temporaryRoot,
                    writer: zipWriter
                )
            }
        }
        let compression = DragOutCompression(zips: jobs, cancellation: cancellation)
        let outcome = compressionOutcome
        DispatchQueue.global(qos: .userInitiated).async {
            outcome.settle(compression.run())
            Task { @MainActor [self] in settleCompression() }
        }
    }

    /// Take in the zips once they are made, for the reason ``settleTransfer()`` is asked twice.
    private func settleCompression() {
        guard handoff.compression == .running, let settled = compressionOutcome.settled else { return }
        zips.merge(settled.zips) { _, zip in zip }
        madeZips += settled.zips.values
        if !isDragging {
            // Finished as the drag ended, after its sweep: nobody can take these now.
            RemoteDragArtifacts.sweep(zips: madeZips, stagedTrees: [], taken: nil)
            madeZips = []
        }
        guard let error = settled.error else {
            apply(handoff.compressionLanded())
            drawStatus()
            return
        }
        handoff.compressionFailed()
        guard !(error is CancellationError) else { return }
        if isDragging { zipFailure = error }
        drawStatus()
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
