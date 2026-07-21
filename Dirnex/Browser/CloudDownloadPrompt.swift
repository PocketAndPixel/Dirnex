import AppKit
import DirnexCore

/// Download-on-open for an evicted iCloud file (PLAN.md §M9 "download on open").
///
/// A dataless item has its real name and its real size and no bytes at all; the first read
/// materializes it, and that read *blocks* — measured at 1.1 s for 200 KB, and a large file on a
/// slow link is far worse. Handing such a path straight to `NSWorkspace` therefore doesn't fail, it
/// beachballs whichever app opened it, with nothing anywhere saying why. So Dirnex asks for the
/// download itself, waits where the user can see it happening (and stop it), and only then opens.
///
/// The decision half is `DirnexCore.CloudDownloadTracker`: this performs the syscall and re-reads
/// the attributes, and the core folds each reading into a phase — including the rule that is easy to
/// get wrong by hand, that a request the provider has not visibly picked up yet is not a failure.
///
/// **The sheet is deliberately late.** A file that is already local never gets here at all, and one
/// the provider hands over in a few hundred milliseconds shouldn't flash a modal on the way — so the
/// wait starts silent and the sheet appears only if the download is still running after
/// `sheetDelay`.
@MainActor
final class CloudDownloadPrompt {
    /// How long a download may run before it is worth interrupting the user with a sheet.
    private static let sheetDelay: Duration = .milliseconds(400)
    /// How often to re-read the item's attributes while waiting. Fast enough that a short download
    /// finishes without a visible sheet, slow enough that it is a handful of reads either way.
    private static let pollInterval: Duration = .milliseconds(250)

    /// Ensure `entry`'s bytes are on this Mac, then run `proceed`.
    ///
    /// Anything that is not an evicted local file proceeds immediately and synchronously, so this
    /// can wrap an open path wholesale without making the common case async or conditional at the
    /// call site. `proceed` does not run at all if the user cancels or the download fails — a
    /// cancelled open opens nothing, and a failure is reported instead.
    static func materialize(
        _ entry: FileEntry,
        using backend: any VFSBackend,
        over window: NSWindow?,
        then proceed: @escaping () -> Void
    ) {
        guard entry.isDataless, entry.path.backend == .local else {
            proceed()
            return
        }
        CloudDownloadPrompt(entry: entry, backend: backend, window: window, proceed: proceed).start()
    }

    private let entry: FileEntry
    private let backend: any VFSBackend
    private weak var window: NSWindow?
    private let proceed: () -> Void

    /// The sheet, once it has been shown. `nil` while the wait is still silent.
    private var alert: NSAlert?
    private var isCancelled = false
    /// Set before the sheet is dismissed from *this* side, so the alert's completion handler can
    /// tell "the download finished" from "the user clicked Stop" — both arrive the same way.
    private var isFinished = false

    private init(
        entry: FileEntry,
        backend: any VFSBackend,
        window: NSWindow?,
        proceed: @escaping () -> Void
    ) {
        self.entry = entry
        self.backend = backend
        self.window = window
        self.proceed = proceed
    }

    private func start() {
        let url = entry.path.localURL
        Task {
            do {
                // The syscall only *asks*; it returns long before any byte arrives, which is why the
                // waiting below reads the item's own attributes rather than trusting this call.
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                }.value
            } catch {
                report(detail: (error as NSError).localizedDescription)
                return
            }
            var tracker = CloudDownloadTracker(isDataless: true)
            tracker.requestSent()
            scheduleSheet()
            await wait(with: tracker)
        }
    }

    /// Poll until the bytes land, the provider gives up, or the user does.
    private func wait(with tracker: CloudDownloadTracker) async {
        var tracker = tracker
        let path = entry.path
        let backend = backend
        while !isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            guard !isCancelled else { return }
            let reading = await Self.read(path, using: backend)
            switch tracker.observe(reading) {
            case .ready:
                dismissSheet()
                proceed()
                return
            case let .failed(reason):
                report(detail: Self.describe(reason))
                return
            case .evicted, .downloading:
                continue
            }
        }
    }

    /// One reading of the item, off the main thread.
    ///
    /// `isDataless` comes from the `stat` the listing itself uses — the ground truth for "would a
    /// read block", and the one value that cannot lag — while the ubiquity attributes say whether
    /// anything is happening. A provider error is only passed on when it is a **verdict** about the
    /// file (`CloudTransferError.isVerdict`): a server the provider merely can't reach right now
    /// rides along with perfectly healthy transfers, and reading it as a failure would abandon a
    /// download that was about to arrive.
    private static func read(_ path: VFSPath, using backend: any VFSBackend) async -> CloudItemReading {
        await Task.detached(priority: .userInitiated) {
            let isDataless = (try? backend.stat(at: path))?.isDataless ?? false
            let attributes = (try? CloudSyncStorage.attributes(at: path)) ?? CloudItemAttributes()
            return CloudItemReading(
                isDataless: isDataless,
                status: attributes.downloadingStatus.flatMap {
                    CloudDownloadStatus(rawValue: $0.rawValue)
                },
                isDownloading: attributes.isDownloading,
                downloadingError: attributes.downloadingError.flatMap(verdict)
            )
        }.value
    }

    // MARK: - The sheet

    /// Show the sheet if the download is still running once `sheetDelay` has passed.
    private func scheduleSheet() {
        Task {
            try? await Task.sleep(for: Self.sheetDelay)
            guard !isFinished, !isCancelled, let window else { return }
            let alert = NSAlert()
            alert.messageText = "Downloading “\(entry.name)”…"
            alert.informativeText = "This item is stored in iCloud. "
                + "Dirnex is fetching it before opening it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Stop")
            alert.enableEscapeToCancel()

            // Indeterminate on purpose: macOS exposes no per-item progress through the resource
            // keys, so a bar that guessed would be inventing numbers the provider never gave.
            let spinner = NSProgressIndicator()
            spinner.style = .bar
            spinner.isIndeterminate = true
            spinner.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
            spinner.startAnimation(nil)
            alert.accessoryView = spinner

            self.alert = alert
            alert.beginSheetModal(for: window) { [weak self] _ in
                // The only button is Stop, so any response that isn't our own dismissal is one.
                guard let self, !isFinished else { return }
                isCancelled = true
            }
        }
    }

    /// Take the sheet down from this side, marking it finished first so its completion handler
    /// doesn't read the dismissal as the user having stopped the download.
    private func dismissSheet() {
        isFinished = true
        guard let alert else { return }
        alert.window.sheetParent?.endSheet(alert.window)
        self.alert = nil
    }

    private func report(detail: String) {
        dismissSheet()
        let alert = NSAlert()
        alert.messageText = "Couldn’t download “\(entry.name)”"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.enableEscapeToCancel()
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// What a provider error means for a *download*, or `nil` when it is not a verdict about the
    /// file at all — `.serverUnavailable` rides along with healthy transfers (docs/NOTES.md), so
    /// treating it as an answer would abandon downloads that were about to arrive.
    nonisolated private static func verdict(_ error: CloudTransferError) -> String? {
        switch error {
        case .serverUnavailable: nil
        case .quotaExceeded: "There isn’t enough iCloud storage to complete this."
        case .itemUnavailable: "The item isn’t available on any device iCloud can reach right now."
        case .other: "iCloud couldn’t provide this item."
        }
    }

    private static func describe(_ reason: CloudDownloadFailure) -> String {
        switch reason {
        case .stalled:
            "iCloud didn’t start the download. Check your network connection and try again."
        case let .provider(detail):
            detail
        }
    }
}
