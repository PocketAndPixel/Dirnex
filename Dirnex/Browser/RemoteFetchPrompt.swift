import AppKit
import DirnexCore

/// Pulling a remote file's bytes down where the user can see it happening, and stop it
/// (PLAN.md §M21 Slice 10).
///
/// Shaped like `CloudDownloadPrompt` — silent start, a sheet only if the wait becomes one, `proceed`
/// only on success — and it differs from that one in three ways, each measured rather than chosen:
///
/// - **The sheet is later.** `CloudDownloadPrompt` shows at 400 ms, tuned against iCloud
///   materialization where the wait is either ~0 (the bytes are already here) or long. A network
///   round trip has no ~0: time to first byte for a *small* object measured **0.512–0.519 s** over
///   five runs against a real endpoint, decomposing as DNS + connect + TLS + server turnaround, and
///   every request is a fresh `curl` because HTTP keeps no session (docs/NOTES.md ▸ curl for S3). So
///   400 ms sits *below the floor*: the sheet would appear on every single preview and be dismissed
///   about a tenth of a second later. ``sheetDelay`` clears that floor with room for an endpoint
///   twice as far away.
/// - **The bar is determinate.** The listing already carries the object's size, so the fraction is a
///   fact rather than a guess — where iCloud exposes no per-item progress at all and an honest bar
///   there can only be a spinner.
/// - **It may ask before it starts.** A remote fetch spends a billed request and somebody's
///   bandwidth, so `RemoteFetchPolicy` decides whether the size is small enough to just happen.
/// - **And it may not report at all.** Where the preview mode's own placeholder card is standing in
///   for the row, that card draws this transfer — so the sheet would be a modal dialog over a
///   progress bar reporting the same bytes (`Context.hasProgressSurface`).
@MainActor
final class RemoteFetchPrompt {
    /// How long a fetch may run before it is worth interrupting the user with a sheet. See the type
    /// comment: this is a *measured* floor, not a feel.
    private static let sheetDelay: Duration = .milliseconds(1200)
    /// How often the sheet re-reads the byte counter the transfer is filling in. Only runs while the
    /// sheet is up, so it is a handful of reads on anything short.
    private static let pollInterval: Duration = .milliseconds(100)

    /// Ensure `entry`'s bytes are on this Mac, then run `proceed` with the local copy.
    ///
    /// A copy already in the cache proceeds immediately and synchronously — which is what makes
    /// preview-then-open-then-edit cost one transfer. `proceed` does not run at all if the user
    /// declines, stops it, or the transfer fails; a failure is handed to `onFailure` so the caller
    /// can word it in its own terms (⌘Y's "couldn't preview" is not F4's "couldn't open").
    static func fetch(
        _ entry: FileEntry,
        for purpose: RemoteFetchPurpose,
        in context: Context,
        onStart: @escaping () -> Void = {},
        then proceed: @escaping (URL) -> Void,
        onFailure: @escaping (any Error) -> Void
    ) {
        if let url = context.cache.cachedURL(for: entry) {
            proceed(url)
            return
        }
        let prompt = RemoteFetchPrompt(
            entry: entry,
            context: context,
            onStart: onStart,
            proceed: proceed,
            onFailure: onFailure
        )
        switch RemoteFetchPolicy.decision(
            forByteSize: prompt.hasKnownSize ? entry.byteSize : nil,
            purpose: purpose,
            previewLimit: AppPreferences.shared.quickViewFetchLimit
        ) {
        case .fetch:
            prompt.start()
        case .confirm:
            prompt.confirm()
        case .decline:
            // Unreachable for the gestures that come through here — only `.cursorPreview` declines,
            // and it does not use this type at all (`RemoteFileCache.scheduleAutomaticFetch` is its
            // whole path, deliberately, because it must never be able to raise a dialog). Named
            // rather than defaulted so a future automatic gesture routed here fails at the compiler
            // instead of silently inheriting the confirmation it exists to avoid.
            break
        }
    }

    /// Fetch `entry` **without weighing its size** — for a caller that has already put that size in
    /// front of the user and been told to go ahead.
    ///
    /// The Quick View placeholder card is the only one: it draws the file's name and size directly
    /// above its Download button, so `RemoteFetchPolicy`'s confirmation would be asking a question
    /// the click has already answered. Everything downstream of the decision is unchanged — the
    /// cache, Stop, the failure report, and the deferred sheet wherever `Context.hasProgressSurface`
    /// says nothing else is drawing this — so this skips the *question* and nothing else.
    ///
    /// A second entry point rather than a `Bool` on the one above, because the two differ in who
    /// decides, not in a setting: here the caller is asserting that the decision has been made.
    static func fetchConfirmed(
        _ entry: FileEntry,
        in context: Context,
        onStart: @escaping () -> Void = {},
        then proceed: @escaping (URL) -> Void,
        onFailure: @escaping (any Error) -> Void
    ) {
        if let url = context.cache.cachedURL(for: entry) {
            proceed(url)
            return
        }
        RemoteFetchPrompt(
            entry: entry,
            context: context,
            onStart: onStart,
            proceed: proceed,
            onFailure: onFailure
        ).start()
    }

    /// Whether the listing gave a size worth believing.
    ///
    /// A negative one is the only way a backend says it did not understand the field — the same
    /// reading `RemoteFetchPolicy` documents, kept in one place here so the confirmation's wording
    /// and the bar's determinacy cannot disagree with the decision that raised them.
    private var hasKnownSize: Bool { entry.byteSize >= 0 }

    /// Everything the fetch needs that is the *same* for every gesture — held together so the
    /// entry point stays about the file and the purpose, which are what actually differ.
    struct Context {
        let backend: any VFSBackend
        let cache: RemoteFileCache
        /// The sheet's host. `nil` falls back to a modal alert, as everywhere else in the app.
        weak var window: NSWindow?
        /// Whether something on screen is already drawing this transfer and offering to call it off
        /// — the Quick View placeholder card, which names the file, carries a determinate bar of its
        /// own and a Stop button, in the very place the preview is about to appear.
        ///
        /// The deferred sheet then stands down. Not because two bars are untidy: the sheet is
        /// *modal*, so it takes the keyboard away from the file list and covers the card that is
        /// reporting the same download — a dialog over a progress bar, both about the same bytes.
        /// Where there is no such surface (⌘Y with Quick View off, ⏎, F4) the sheet is still the
        /// only thing that can say anything, and it appears exactly as it did.
        var hasProgressSurface = false
    }

    private let entry: FileEntry
    private let context: Context
    /// Called the moment the transfer actually begins — which for a confirmed fetch is when the user
    /// answers, not when this object was made. What it is *for* is the placeholder card: the card is
    /// drawn from a snapshot the pane took before the question was asked, so without this it goes on
    /// offering a Download button for a download already under way.
    private let onStart: () -> Void
    private let proceed: (URL) -> Void
    private let onFailure: (any Error) -> Void

    /// How far the transfer has got and whether it has been told to stop. Both are read and written
    /// from the transfer's own thread, so neither can be main-actor state — and both are handed to
    /// the cache, which is what lets the placeholder card draw this transfer and its Stop button end
    /// it, rather than the sheet being the only thing that can.
    private let moved = ByteCounter()
    private let cancellation = CancellationFlag()
    /// The sheet, once it has been shown. `nil` while the wait is still silent.
    private var alert: NSAlert?
    private var bar: NSProgressIndicator?
    /// Set before the sheet is dismissed from *this* side, so its completion handler can tell "the
    /// transfer finished" from "the user pressed Stop" — both arrive the same way.
    private var isFinished = false

    private init(
        entry: FileEntry,
        context: Context,
        onStart: @escaping () -> Void,
        proceed: @escaping (URL) -> Void,
        onFailure: @escaping (any Error) -> Void
    ) {
        self.entry = entry
        self.context = context
        self.onStart = onStart
        self.proceed = proceed
        self.onFailure = onFailure
    }

    // MARK: - Asking first

    /// Name the size and let the user decide, for a file over `RemoteFetchPolicy`'s threshold — or
    /// one whose size the backend never reported, which is exactly when not knowing how much is
    /// about to be pulled makes the question worth asking.
    private func confirm() {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Download “\(entry.name)” from the server?",
            comment: "Title of the confirmation before fetching a large remote file; %@ is the name."
        )
        alert.informativeText = hasKnownSize
            ? String(
                localized: """
                This file is \(FileFormatting.byteString(entry.byteSize)). Dirnex has to download \
                it before it can be shown.
                """,
                comment: """
                Body of the large-remote-file confirmation; %@ is a formatted size such as “84 MB”.
                """
            )
            : String(
                localized: """
                The server didn’t report how large this file is. Dirnex has to download it before \
                it can be shown.
                """,
                comment: "Body of the remote-fetch confirmation when the size is unknown."
            )
        alert.addButton(withTitle: String(
            localized: "Download",
            comment: "Button that starts downloading a remote file."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        // `NSAlert` binds Escape by matching the byte string "Cancel", which a translated title is
        // not — so the response says which button ⎋ means (docs/NOTES.md ▸ Localization).
        alert.enableEscapeToCancel(safe: .alertSecondButtonReturn)

        // Captured **strongly**, and that is the whole of the fix rather than a style choice.
        // Nothing else holds this object across the sheet: `fetch` makes it in a local, `confirm`
        // returns the moment `beginSheetModal` has been asked (it is asynchronous), and the alert
        // retains the *closure*, not us. With `[weak self]` the prompt was therefore gone by the
        // time anybody could answer — so pressing Download sent `start()` to `nil` and the dialog
        // simply closed, with no transfer, nothing logged, and the placeholder card still offering
        // the button. Reported by a user 2026-08-19. The `start()` path never had it, because the
        // `Task` it launches captures `self` strongly, which is exactly why the two behaved
        // differently for the same click. No cycle: the closure is AppKit's, released with the
        // sheet.
        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            self.start()
        }
        if let window = context.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    // MARK: - The transfer

    private func start() {
        // Both **before** the transfer's task gets a chance to run, and in this order. The record is
        // what the placeholder card reads to draw a bar instead of a button, and `onStart` is what
        // asks for that card to be re-drawn — so a redraw arriving first would find nothing running
        // and put the Download button back under a download already on its way.
        context.cache.beginExplicitFetch(entry.path, moved: moved, cancellation: cancellation)
        onStart()
        let moved = moved
        let cancellation = cancellation
        Task {
            scheduleSheet()
            do {
                let url = try await context.cache.fetch(
                    entry,
                    using: context.backend,
                    progress: { moved.value = $0 },
                    isCancelled: { cancellation.isCancelled }
                )
                finish()
                proceed(url)
            } catch is CancellationError {
                // The user's own answer, already on screen. Nothing to report, and nothing left on
                // disk — the cache removed the partial.
                finish()
            } catch {
                finish()
                onFailure(error)
            }
        }
    }

    /// Take down whatever was reporting this transfer, however it ended: the sheet if one went up,
    /// and the cache's record of it — which the card reads, and which a *stopped* transfer keeps
    /// (see `RemoteFileCache.endExplicitFetch`) so the card can say so.
    private func finish() {
        dismissSheet()
        context.cache.endExplicitFetch(entry.path)
    }

    /// Show the sheet if the transfer is still running once `sheetDelay` has passed, and keep its
    /// bar following the byte counter until it is taken down.
    private func scheduleSheet() {
        // The placeholder card is already naming this file, drawing its bar and offering Stop, in
        // the surface the preview itself is about to appear in. A modal sheet on top of it reports
        // the same bytes twice and takes the keyboard away from the list to do it.
        guard !context.hasProgressSurface else { return }
        Task {
            try? await Task.sleep(for: Self.sheetDelay)
            guard !isFinished, !cancellation.isCancelled, let window = context.window else {
                return
            }
            let alert = NSAlert()
            alert.messageText = String(
                localized: "Downloading “\(entry.name)”…",
                comment: "Remote download progress title; %@ is the file name."
            )
            alert.informativeText = String(
                localized: "Dirnex is fetching this file from the server before opening it.",
                comment: "Remote download progress body."
            )
            alert.alertStyle = .informational
            alert.addButton(
                withTitle: String(localized: "Stop", comment: "Button that cancels the download.")
            )
            alert.enableEscapeToCancel()

            let bar = NSProgressIndicator()
            bar.style = .bar
            // Determinate whenever the listing gave a size, which is the ordinary case — the fraction
            // is then a fact. A backend that reported none gets the honest spinner instead.
            bar.isIndeterminate = !hasKnownSize
            bar.minValue = 0
            bar.maxValue = Double(max(entry.byteSize, 1))
            bar.frame = NSRect(x: 0, y: 0, width: 260, height: 16)
            if bar.isIndeterminate { bar.startAnimation(nil) }
            alert.accessoryView = bar

            self.alert = alert
            self.bar = bar
            alert.beginSheetModal(for: window) { [weak self] _ in
                // The only button is Stop, so any response that isn't our own dismissal is one.
                guard let self, !isFinished else { return }
                cancellation.isCancelled = true
            }
            await followProgress()
        }
    }

    /// Poll the byte counter while the sheet is up.
    ///
    /// Polling rather than hopping to the main actor per chunk: a chunked transfer reports often
    /// enough that a hop each time is churn nobody sees, and the sheet only exists for transfers
    /// long enough that a tenth of a second of lag in the bar is invisible.
    private func followProgress() async {
        while !isFinished, !cancellation.isCancelled, bar != nil {
            try? await Task.sleep(for: Self.pollInterval)
            bar?.doubleValue = Double(moved.value)
        }
    }

    /// Take the sheet down from this side, marking it finished first so its completion handler does
    /// not read the dismissal as the user having stopped the transfer.
    private func dismissSheet() {
        isFinished = true
        bar = nil
        guard let alert else { return }
        alert.window.sheetParent?.endSheet(alert.window)
        self.alert = nil
    }
}
