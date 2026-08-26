import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The fetch somebody *did* press a key for: the confirmation in front of it, and who draws it while
/// it runs (PLAN.md §M21 Slice 10).
///
/// Two bugs live here, reported together on 2026-08-19 against a 14,5 MB object on S3 with ⌃Q. The
/// dialog's **Download button did nothing** — nothing was retained across the sheet, so the answer
/// arrived at a deallocated prompt and the transfer was never started; and the download that *did*
/// run (from the card's own button) put a second **progress dialog** over the placeholder card,
/// which is the surface already standing in that spot to report exactly this.
///
/// Every wait is an `await`, never a run-loop spin — what is being waited for is a detached
/// transfer's continuation, and a spin never suspends the main actor (docs/NOTES.md ▸ Testing).
@MainActor
@Suite("Remote fetch prompt")
struct RemoteFetchPromptTests {
    /// Bigger than `RemoteFetchPolicy.previewLimitRange` can reach, so the decision is `.confirm`
    /// whatever limit the machine running the tests happens to have set — the app test target runs
    /// *inside* the app and reads the real preference domain.
    private static let unmissablySized: Int64 = 8 * 1_000_000_000

    /// The reported bug, at the one place it can be caught: press the dialog's own default button
    /// and a transfer has to begin.
    ///
    /// The assertion is the **backend's** copy count rather than anything the prompt returns,
    /// because what broke was not a decision — the code chose `.confirm`, drew the right dialog and
    /// read the right response. It sent `start()` to a `nil` `self`. So the only thing that can tell
    /// the fixed version from the broken one is whether the transfer was asked for.
    @Test("the confirmation's Download button starts the transfer")
    func confirmationDownloadStartsTheTransfer() async throws {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetch(
            entry,
            for: .preview,
            in: .init(
                backend: backend, cache: cache, window: window, hasProgressSurface: true
            ),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the confirmation never appeared")
        try #require(Self.defaultButton(in: sheet)).performClick(nil)
        await settle { backend.copyCount == 1 }

        #expect(backend.copyCount == 1)
        cache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer }
    }

    /// The narrowness control, and it is the one that says the test above is about the button rather
    /// than about the dialog merely closing: the *other* answer must still start nothing.
    @Test("dismissing the confirmation starts nothing")
    func confirmationCancelStartsNothing() async throws {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetch(
            entry,
            for: .preview,
            in: .init(
                backend: backend, cache: cache, window: window, hasProgressSurface: true
            ),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        await hold()

        #expect(backend.copyCount == 0)
        #expect(cache.previewFetchState(for: entry) == nil)
    }

    /// What makes the card able to replace the sheet at all: a transfer an explicit gesture is
    /// running has to be visible where the *automatic* one already was, since the card reads one
    /// question — "what is happening to the row I am standing in for" — and draws one answer.
    ///
    /// `onStart` is asserted beside it, and it is not decoration: the card is drawn from a snapshot
    /// taken before the dialog was answered, so without that call it goes on offering a Download
    /// button over a download already under way — the visible half of the bug.
    @Test("an explicit fetch is reported to the placeholder card, and says when it began")
    func explicitFetchIsReportedToTheCard() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)
        let started = Counter()

        RemoteFetchPrompt.fetchConfirmed(
            entry,
            in: .init(backend: backend, cache: cache, window: nil, hasProgressSurface: true),
            onStart: { started.times += 1 },
            then: { _ in },
            onFailure: { _ in }
        )
        // Synchronously, before the transfer's own task has run: the redraw it causes must find the
        // fetch already recorded, or it puts the button back under a running download.
        #expect(started.times == 1)
        #expect(cache.previewFetchState(for: entry) == .running)
        await settle { cache.previewFetchProgress(for: entry) == CountingBackend.blockedChunk }

        #expect(cache.previewFetchProgress(for: entry) == CountingBackend.blockedChunk)
        #expect(cache.previewFetchProgress(for: Fixture.entry("other.jpg")) == nil)
        // The only test here that asserts nothing about stopping still has to stop: a `.block`
        // transfer now runs until it is told to, so leaving it would hold a `BlockingWork` thread
        // in a `usleep` loop for the rest of the run (``CountingBackend.blockBackstop``).
        cache.stopPreviewFetch()
    }

    /// The card's Stop button, on a transfer the card did not start. With the sheet standing down
    /// this is the *only* way to call an explicit download off, so "it reaches the transfer" is the
    /// whole claim — and the evidence is the backend's own record of having been told, never the
    /// `CancellationError` a boundary check throws either way.
    @Test("Stop on the card reaches an explicit transfer, and the card says so afterwards")
    func stopReachesAnExplicitTransfer() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetchConfirmed(
            entry,
            in: .init(backend: backend, cache: cache, window: nil, hasProgressSurface: true),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { backend.copyCount == 1 }
        cache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer }

        #expect(backend.wasCancelledMidTransfer)
        // And the fact survives the transfer's own unwinding, which arrives immediately after and
        // would otherwise erase the one thing the card is about to say.
        await hold()
        #expect(cache.previewFetchState(for: entry) == .stopped)
        #expect(cache.cachedURL(for: entry) == nil)
    }

    /// The second half of the report: no dialog over the card.
    ///
    /// **Paced by a sheet that has to appear, rather than by a constant** — which is the whole
    /// difference between this and a green test that proves nothing. It used to hold for 2.5 s, on
    /// the reasoning that this clears the prompt's own 1200 ms delay twice over. In a full run that
    /// delay is not what decides when a sheet goes up: the main actor is stalled 0.6–5.0 s at a time
    /// and the sheet actually lands **2.9–6.3 s** in (▸ ``CountingBackend.blockBackstop``), so the
    /// hold expired before one could have appeared either way. Measured 2026-08-27 by deleting
    /// `scheduleSheet`'s `hasProgressSurface` guard: **3 of 3 full runs still passed**, while the
    /// same build run *alone* raised the sheet — a control that only fires on an idle Mac.
    ///
    /// So a second, identical fetch runs beside it on its own window with nothing else reporting,
    /// and that one says when to look. It is started **after** the covered fetch, so its sheet task
    /// is created after and its timer fires no earlier: by the time the pacer's sheet is up, the
    /// covered one's would have been.
    @Test("no progress sheet goes up while the placeholder card is drawing the transfer")
    func noSheetWhereTheCardReports() async throws {
        let covered = Self.probeWindow()
        let pacer = Self.probeWindow()
        defer {
            covered.close()
            pacer.close()
        }
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)
        let pacerBackend = CountingBackend(outcome: .block)
        let pacerCache = RemoteFileCache()
        let pacerEntry = Fixture.entry("pacer.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetchConfirmed(
            entry,
            in: .init(
                backend: backend, cache: cache, window: covered, hasProgressSurface: true
            ),
            then: { _ in },
            onFailure: { _ in }
        )
        RemoteFetchPrompt.fetchConfirmed(
            pacerEntry,
            in: .init(
                backend: pacerBackend, cache: pacerCache, window: pacer,
                hasProgressSurface: false
            ),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { pacer.attachedSheet != nil }
        let paced = try #require(pacer.attachedSheet, "the pacing sheet never appeared")

        #expect(covered.attachedSheet == nil)
        pacer.endSheet(paced)
        cache.stopPreviewFetch()
        pacerCache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer && pacerBackend.wasCancelledMidTransfer }
    }

    /// The control that keeps the rule from becoming "never report anything": ⌘Y with Quick View
    /// off, ⏎ and F4 have no card, and there the sheet is the only thing that can say a transfer is
    /// running at all.
    @Test("the progress sheet still appears where nothing else is drawing the transfer")
    func sheetAppearsWhereNothingElseReports() async throws {
        let window = Self.probeWindow()
        defer { window.close() }
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetchConfirmed(
            entry,
            in: .init(backend: backend, cache: cache, window: window, hasProgressSurface: false),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet, "the progress sheet never appeared")

        window.endSheet(sheet)
        cache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer }
    }

    /// The cursor-following fetch stands aside for a row somebody has pressed a key for. Without it
    /// a delivery arriving mid-download — and the redraw the card's own button causes is one — would
    /// issue a *second* transfer of the same object beside the one on screen.
    @Test("the automatic fetch stands aside for a row an explicit one is already fetching")
    func automaticStandsAsideForAnExplicitFetch() async {
        let backend = CountingBackend(outcome: .block)
        let cache = RemoteFileCache()
        let entry = Fixture.entry("panorama.jpg", byteSize: Self.unmissablySized)

        RemoteFetchPrompt.fetchConfirmed(
            entry,
            in: .init(backend: backend, cache: cache, window: nil, hasProgressSurface: true),
            then: { _ in },
            onFailure: { _ in }
        )
        await settle { backend.copyCount == 1 }
        for _ in 0..<3 {
            cache.scheduleAutomaticFetch(entry, using: backend, onSettled: {})
        }
        await hold { backend.copyCount > 1 }

        #expect(backend.copyCount == 1)
        cache.stopPreviewFetch()
        await settle { backend.wasCancelledMidTransfer }
    }

    // MARK: - Plumbing

    /// A window to hang a sheet on. Never ordered front: a sheet attaches and answers without it,
    /// and a test that puts a window on somebody's screen is a test that interrupts them.
    private static func probeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }

    /// The button an alert binds Return to — its first, found without reading a title, which would
    /// pass in English and fail in thirteen languages (docs/NOTES.md ▸ Localization).
    ///
    /// Through the window's `defaultButtonCell`, because on macOS 26 a modern alert's confirming
    /// button carries **no** `keyEquivalent` at all — dumped from a live sheet here, its two buttons
    /// read `Cancel ke="\u{1B}"` and `Download ke=""`. This file's own notes record that shape for a
    /// sheet holding a text-field accessory; it is true of a plain one too, and a scan for `"\r"`
    /// therefore finds nothing and reads as the dialog having no default button. The scan stays as
    /// the fallback, since it is what an alert built any other way would answer to.
    private static func defaultButton(in window: NSWindow) -> NSButton? {
        if let button = window.defaultButtonCell?.controlView as? NSButton { return button }
        guard let content = window.contentView else { return nil }
        return defaultButton(under: content)
    }

    private static func defaultButton(under view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton, button.keyEquivalent == "\r" { return button }
            if let found = defaultButton(under: subview) { return found }
        }
        return nil
    }

    /// Poll until `isDone` — `await`, never a run-loop spin, since what is being waited for is a
    /// transfer's continuation and a spin never suspends the main actor (docs/NOTES.md ▸ Testing).
    ///
    /// **Generous on purpose, and that costs nothing.** A satisfied predicate returns on the next
    /// poll, so the budget never lengthens a green run — it only decides how much scheduling delay
    /// the test can absorb before reporting a failure that is really the machine's. The old budget
    /// was 2.5 s against a 1200 ms sheet delay, about 2×, and it expired on a loaded Mac and read
    /// as a dead button (2026-08-20).
    ///
    /// 10 s was the next one and was still too near the measurement. In a full run the main actor
    /// is delayed **0.6–5.0 s at a time** by AppKit laying out the tables of panes other suites keep
    /// alive, so this loop gets roughly one sample a second and the 1200 ms sheet lands 2.9–6.3 s in
    /// (measured 2026-08-27, ▸ ``CountingBackend.blockBackstop``). 30 s is about five times the
    /// worst of that, and a green run still returns on the poll after the predicate holds.
    ///
    /// It is **not** how to wait a delay out — that is ``hold(until:)``, which is bounded because
    /// the length is the whole point of it.
    @discardableResult
    private func settle(within seconds: Double = 30, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return isDone()
    }

    /// Wait long enough to show something does *not* happen, giving up early if it ever does so a
    /// real failure is reported promptly rather than after the whole wait.
    ///
    /// Bounded, unlike ``settle(within:until:)``, and it has to be: here the length is the claim,
    /// so it cannot be widened to suit a slow machine. Which is exactly why the *sheet* no longer
    /// waits on this — a constant cannot outlast a main actor that is late by seconds, and one that
    /// tried was measured vacuous (▸ ``noSheetWhereTheCardReports()``).
    ///
    /// The three waits left on it were each put under their own negative control in a full run on
    /// 2026-08-27 and each still failed 3 of 3, so 2.5 s does cover what they are watching for: an
    /// answered confirmation starting a transfer, a stopped fetch being forgotten, and an automatic
    /// fetch issuing a second copy. All three are settled by work already in flight rather than by
    /// a timer nobody has armed yet, which is what makes the constant hold for them and not there.
    private func hold(until isHappening: () -> Bool = { false }) async {
        _ = await settle(within: 2.5, until: isHappening)
    }

    /// A main-actor tally, for counting calls a closure makes.
    @MainActor
    private final class Counter {
        var times = 0
    }
}
