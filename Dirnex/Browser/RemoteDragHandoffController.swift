import AppKit
import DirnexCore

/// One drag of rows whose bytes are on a server, while it is under way: what lets such a row drop into
/// Teams, Slack, Chrome and everything else that only takes a real file.
///
/// `RemoteDragHandoff` holds the rules and says why each is there. This object does what they ask:
/// it watches which app is under the pointer, rewrites the drag's board, brings the bytes down and
/// answers the reads. A drop into Finder never involves it, because Finder takes the promise the drag
/// started with and `+DragPromise` fulfils that as it always has.
///
/// **The bytes land in the cache and do not go through the queue.** A queued job is something the user
/// asked for, reported per item with a Stop button in a window they have left, and this is something
/// the pointer did on its way across the screen. So a row already fetched for a preview costs nothing
/// here, and what this brings down serves the next preview and the next drag.
///
/// **The transfer needs nothing from the main thread until it is over**, because a held read is
/// sitting on that thread waiting for it. It runs off the main actor and leaves its outcome in a box
/// the hold looks at. The first version kept the run loop turning during a hold and awaited
/// `RemoteFileCache.fetch`, whose last step is on the main actor: a run loop nested inside a main-queue
/// job does not drain the main queue, so the read could wait the whole limit on a transfer that had
/// finished. Turning the run loop bought nothing anyway, since the drag does not move during a read.
@MainActor
final class RemoteDragHandoffController {
    private var handoff = RemoteDragHandoff()
    /// The drag session's own board.
    private let board: NSPasteboard
    /// Every row of the drag, in order, including any a file URL cannot stand for (a folder, a row in
    /// an archive), which the board keeps carrying exactly as `PanelPasteboard` does for them.
    let entries: [FileEntry]
    private let cache: RemoteFileCache
    private let backend: any VFSBackend
    private let holdLimit: Duration
    /// Who is under the pointer. Injected because a test has no pointer to move.
    private let surfaceUnderPointer: @MainActor () -> RemoteDragHandoff.Surface
    private let showStatus: (String?) -> Void
    private let onLanded: () -> Void
    private let onFailure: (any Error) -> Void

    /// The copies landed so far, by the row they are of.
    private var files: [VFSPath: URL] = [:]
    /// Written by the transfer's own thread and read when the status is drawn.
    private let moved = ByteCounter()
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

    /// The rows of `entries` this has to bring down.
    private var remoteRows: [FileEntry] {
        entries.filter(RemoteFilePromiseProvider.canPromise)
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
        onFailure: @escaping (any Error) -> Void
    ) {
        self.board = board
        self.entries = entries
        self.cache = cache
        self.backend = backend
        self.holdLimit = holdLimit
        self.surfaceUnderPointer = surfaceUnderPointer
        self.showStatus = showStatus
        self.onLanded = onLanded
        self.onFailure = onFailure
    }

    // MARK: - The drag

    /// The pointer moved. Has to be cheap and has to be prompt: the app under it reads the board a few
    /// milliseconds after this returns.
    func pointerMoved() {
        apply(handoff.pointerMoved(over: surfaceUnderPointer()))
    }

    /// The drag is over, whichever way. `mayFinish` is whether a transfer still running may carry on
    /// with nobody watching.
    func dragEnded(mayFinish: Bool) {
        isDragging = false
        statusTask?.cancel()
        apply(handoff.dragEnded(mayFinish: mayFinish))
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
        return files[entry.path]?.absoluteString
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
                providers = remoteRows.map { FileURLProvider(entry: $0, owner: self) }
                let byPath = Dictionary(
                    providers.map { ($0.entry.path, $0) }, uniquingKeysWith: { first, _ in first }
                )
                write(PanelPasteboard.handoffItems(for: entries) { entry in
                    byPath[entry.path].map { .answeredWhenRead($0) }
                })
            case .writeFileURLs:
                write(PanelPasteboard.handoffItems(for: entries) { [files] entry in
                    files[entry.path].map { .here($0) }
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
        for row in rows {
            if let held = cache.cachedURL(for: row) { files[row.path] = held }
        }
        let missing = rows.filter { files[$0.path] == nil }
        guard !missing.isEmpty else {
            landed()
            return
        }
        // Two transfers of the row the cursor is on would otherwise race for one object.
        cache.cancelAutomaticFetch()
        followProgress(ofBytes: missing.map(\.byteSize))
        runTransfer(of: missing)
    }

    /// Bring `rows` down on a thread of their own, and come back to the main actor once they are done.
    private func runTransfer(of rows: [FileEntry]) {
        let root = RemoteFileCache.temporaryRoot.path
        let backend = backend
        let moved = moved
        let cancellation = cancellation
        let outcome = outcome
        DispatchQueue.global(qos: .userInitiated).async {
            var landed: [MaterializedFile] = []
            var done: Int64 = 0
            do {
                for row in rows {
                    let before = done
                    try landed.append(MaterializeRunner.materialize(
                        row,
                        intoDirectory: root,
                        using: backend,
                        onBytes: { moved.value = before + $0 },
                        isCancelled: { cancellation.isCancelled }
                    ))
                    done += max(row.byteSize, 0)
                }
                outcome.settle(landed: landed, error: nil)
            } catch {
                outcome.settle(landed: landed, error: error)
            }
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
            showStatus(RemoteDragStatus.downloading(moved: moved.value, of: total))
        case .landed:
            // Worth saying only to an app that was already told there was nothing, because it will
            // not look again until the pointer leaves it and comes back.
            showStatus(handoff.board == .fileURLs ? RemoteDragStatus.ready : nil)
        case .failed:
            showStatus(RemoteDragStatus.failed)
        }
    }
}

/// What a transfer ended with, handed from its own thread to the main actor.
///
/// A box rather than an `await`, because whoever wants it may be holding the main thread.
private final class RemoteDragTransferOutcome: @unchecked Sendable {
    struct Settled {
        let landed: [MaterializedFile]
        let error: (any Error)?
    }

    private let lock = NSLock()
    private var value: Settled?

    var settled: Settled? {
        lock.withLock { value }
    }

    var isSettled: Bool {
        settled != nil
    }

    func settle(landed: [MaterializedFile], error: (any Error)?) {
        lock.withLock { value = Settled(landed: landed, error: error) }
    }
}

/// What is under the pointer during a real drag.
@MainActor
enum RemoteDragPointer {
    /// Asked through the window server, since the answer is about other apps' windows and the drag's
    /// own image is not one it reports. About 0.3 ms when measured, which a drag's moves can afford.
    static func surface() -> RemoteDragHandoff.Surface {
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number))
              as? [[String: Any]],
              let processID = info.first?[kCGWindowOwnerPID as String] as? pid_t else {
            return .neutral
        }
        let app = NSRunningApplication(processIdentifier: processID)
        return .classify(
            processID: processID,
            bundleIdentifier: app?.bundleIdentifier,
            isRegularApp: app?.activationPolicy == .regular,
            ownProcessID: ProcessInfo.processInfo.processIdentifier
        )
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
